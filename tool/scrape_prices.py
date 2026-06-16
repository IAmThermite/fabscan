#!/usr/bin/env python3
"""Scrapes current prices for every print in ``card.json`` and writes a single
``prices.json`` the FabScan app downloads (≤1x/24h) and serves offline.

Sources (each isolated — one failing never aborts the run):
  * MinMaxGames (AUD) and Fluke & Box (NZD): Shopify storefronts. We crawl each
    store's public ``/products.json`` once and match products/variants to prints.
  * TCGplayer (USD): per-print, via the product id embedded in each print's
    ``tcgplayer_url`` and TCGplayer's own ``mpapi`` price-points endpoint.
  * Cardmarket (EUR): best-effort; usually degrades to link-out (Cloudflare bot
    protection, no per-print URL in card.json). Attempted, then omitted on failure.

Prices are stored in each source's own currency; the app converts at view time
using the ``fx`` block (rates fetched once from a free, no-key API).

The per-source keys in the output MUST byte-match the app's ``PriceSource.name``
values: ``MinMaxGames``, ``Fluke & Box``, ``TCGplayer``, ``Cardmarket``. A
mismatch silently downgrades that source to a link-out in the app.

Output (short keys keep the file small; only prints with >=1 price are included):
  { "schema_version": 1, "generated_at": "ISO8601",
    "fx": {"base":"USD","as_of":"YYYY-MM-DD","rates":{...}},
    "prints": { "<unique_id>": { "MinMaxGames": {"p":12.5,"c":"AUD","u":"...","s":true} } } }

Usage:
  python tool/scrape_prices.py [--from <card.json|url>] [--out dist/]
                               [--limit N] [--no-tcg] [--no-shopify] [--no-cm]
"""

import argparse
import datetime as _dt
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

try:
    import requests
except ImportError:  # pragma: no cover
    sys.stderr.write("This script needs `requests` (pip install requests)\n")
    raise

SCHEMA_VERSION = 1
DEFAULT_CARD_JSON = "flesh-and-blood-cards/json/english/card.json"
DEFAULT_OUT_DIR = "dist"

# Currencies we ship FX rates for (must cover every source currency below).
FX_CURRENCIES = ["USD", "AUD", "NZD", "EUR", "GBP"]

USER_AGENT = "fabscan-price-scraper/1.0 (+https://github.com/IAmThermite/fabscan)"

_PUNCT = re.compile(r"[^a-z0-9 ]+")
_WS = re.compile(r"\s+")


def normalize(s):
    if not s:
        return ""
    s = s.lower().replace("&", " and ")
    s = _PUNCT.sub(" ", s)
    return _WS.sub(" ", s).strip()


# --------------------------------------------------------------------------- #
# card.json loading
# --------------------------------------------------------------------------- #

def _read_source(path_or_url):
    if path_or_url.startswith(("http://", "https://")):
        with urllib.request.urlopen(path_or_url, timeout=60) as resp:  # noqa: S310
            return resp.read()
    with open(path_or_url, "rb") as f:
        return f.read()


class Print:
    """The fields we need from one printing of one card."""

    __slots__ = ("id", "name", "norm_name", "set_id", "foiling", "edition",
                 "art_variations", "tcgplayer_url")

    def __init__(self, card, pr):
        self.id = pr["unique_id"]
        self.name = card["name"]
        self.norm_name = normalize(card["name"])
        self.set_id = (pr.get("set_id") or "").strip()
        self.foiling = (pr.get("foiling") or "").strip()
        self.edition = (pr.get("edition") or "").strip()
        self.art_variations = pr.get("art_variations") or []
        url = (pr.get("tcgplayer_url") or "").strip()
        self.tcgplayer_url = url or None


def load_prints(src, limit=None):
    data = json.loads(_read_source(src))
    if not isinstance(data, list):
        sys.stderr.write(f"Expected a JSON array at {src}\n")
        sys.exit(1)
    if limit is not None:
        data = data[:limit]
    prints = []
    for card in data:
        for pr in (card.get("printings") or []):
            prints.append(Print(card, pr))
    return prints


# --------------------------------------------------------------------------- #
# FX rates
# --------------------------------------------------------------------------- #

def fetch_fx():
    """Free, no-key rates relative to USD. Returns an fx dict, or None on failure."""
    try:
        r = requests.get("https://open.er-api.com/v6/latest/USD",
                         headers={"User-Agent": USER_AGENT}, timeout=20)
        r.raise_for_status()
        body = r.json()
        rates = body.get("rates") or {}
        picked = {c: float(rates[c]) for c in FX_CURRENCIES if c in rates}
        if "USD" not in picked:
            picked["USD"] = 1.0
        as_of = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d")
        return {"base": "USD", "as_of": as_of, "rates": picked}
    except Exception as e:  # noqa: BLE001
        sys.stderr.write(f"[fx] failed: {e}\n")
        return None


# --------------------------------------------------------------------------- #
# Shopify storefronts (MinMaxGames, Fluke & Box)
# --------------------------------------------------------------------------- #

# Set codes we recognise as a token in a Shopify product title (lowercased).
def _set_token(set_id):
    return normalize(set_id)


# Art-variation -> words that tend to appear in a product title.
_ART_WORDS = {
    "EA": ["extended art", "extended"],
    "FA": ["full art", "full"],
    "AA": ["alternate art", "alt art"],
    "AB": ["alternate border", "borderless"],
    "AT": ["alternate text"],
}


class ShopifyStore:
    """Crawls a store's public catalogue and matches prints to product prices."""

    def __init__(self, name, base_url, currency, session):
        self.name = name
        self.base_url = base_url.rstrip("/")
        self.currency = currency
        self.session = session
        self.products = []  # list of dicts: {norm_title, url, price, available}

    def crawl(self):
        page = 1
        total = 0
        while True:
            url = f"{self.base_url}/products.json?limit=250&page={page}"
            try:
                r = self.session.get(url, timeout=30)
                if r.status_code != 200:
                    break
                products = r.json().get("products") or []
            except Exception as e:  # noqa: BLE001
                sys.stderr.write(f"[{self.name}] page {page} failed: {e}\n")
                break
            if not products:
                break
            for p in products:
                self._index_product(p)
            total += len(products)
            if len(products) < 250:
                break
            page += 1
            if page > 200:  # safety bound
                break
        sys.stderr.write(f"[{self.name}] indexed {total} products "
                         f"({len(self.products)} priced)\n")

    def _index_product(self, p):
        title = p.get("title") or ""
        handle = p.get("handle") or ""
        variants = p.get("variants") or []
        # Cheapest in-stock variant price (fall back to cheapest of any).
        prices_avail = []
        prices_any = []
        for v in variants:
            try:
                price = float(v.get("price"))
            except (TypeError, ValueError):
                continue
            prices_any.append(price)
            if v.get("available"):
                prices_avail.append(price)
        chosen = min(prices_avail) if prices_avail else (
            min(prices_any) if prices_any else None)
        if chosen is None:
            return
        self.products.append({
            "norm_title": normalize(title),
            "url": f"{self.base_url}/products/{handle}" if handle else self.base_url,
            "price": chosen,
            "available": bool(prices_avail),
        })

    def price_for(self, pr):
        """Best product match for a print -> (price, url, in_stock) or None."""
        if not pr.norm_name:
            return None
        set_tok = _set_token(pr.set_id)
        art_words = []
        for code in pr.art_variations:
            art_words += _ART_WORDS.get(code, [])

        best = None
        best_score = 0
        for prod in self.products:
            title = prod["norm_title"]
            if pr.norm_name not in title:
                continue
            score = 1
            if set_tok and set_tok in title:
                score += 2
            if art_words and any(w in title for w in art_words):
                score += 2
            elif not pr.art_variations and not any(
                    w in title for words in _ART_WORDS.values() for w in words):
                # Plain print prefers a plain title (no art-variant words).
                score += 1
            if score > best_score:
                best_score = score
                best = prod
        if best is None:
            return None
        return (best["price"], best["url"], best["available"])


# --------------------------------------------------------------------------- #
# TCGplayer (per-print via product id)
# --------------------------------------------------------------------------- #

_TCG_PRODUCT_RE = re.compile(r"/product/(\d+)")


def _tcg_product_id(url):
    if not url:
        return None
    m = _TCG_PRODUCT_RE.search(url)
    return m.group(1) if m else None


def _tcg_price(session, product_id):
    """Market (or low) price for a TCGplayer product id, or None."""
    url = f"https://mpapi.tcgplayer.com/v2/product/{product_id}/pricepoints"
    try:
        r = session.get(url, timeout=20)
        if r.status_code != 200:
            return None
        points = r.json()
        if not isinstance(points, list):
            return None
        candidates = []
        for pt in points:
            for key in ("marketPrice", "lowPrice", "midPrice"):
                v = pt.get(key)
                if isinstance(v, (int, float)) and v > 0:
                    candidates.append(float(v))
                    break
        return min(candidates) if candidates else None
    except Exception:  # noqa: BLE001
        return None


def scrape_tcgplayer(prints, session, workers=8):
    """Returns {print_id: (price, url, in_stock)} for prints with a tcgplayer_url."""
    targets = [p for p in prints if _tcg_product_id(p.tcgplayer_url)]
    out = {}

    def work(p):
        pid = _tcg_product_id(p.tcgplayer_url)
        price = _tcg_price(session, pid)
        if price is not None:
            return p.id, (price, p.tcgplayer_url, True)
        return None

    with ThreadPoolExecutor(max_workers=workers) as ex:
        futures = [ex.submit(work, p) for p in targets]
        for fut in as_completed(futures):
            res = fut.result()
            if res:
                out[res[0]] = res[1]
    sys.stderr.write(f"[TCGplayer] priced {len(out)}/{len(targets)} prints "
                     f"with a product page\n")
    return out


# --------------------------------------------------------------------------- #
# Cardmarket (best-effort; usually degrades to link-out)
# --------------------------------------------------------------------------- #

def scrape_cardmarket(prints, session):
    """Cardmarket has no open price API and aggressive bot protection, and
    card.json carries no per-print Cardmarket URL. There is no reliable,
    ToS-respecting way to scrape per-print prices here, so this returns nothing
    and the app falls back to the Cardmarket search link. Left as a clearly
    marked hook for a future data source."""
    sys.stderr.write("[Cardmarket] no scrape source available -> link-out only\n")
    return {}


# --------------------------------------------------------------------------- #
# Assembly
# --------------------------------------------------------------------------- #

def _make_session():
    s = requests.Session()
    s.headers.update({"User-Agent": USER_AGENT, "Accept": "application/json"})
    return s


def build(prints, do_shopify=True, do_tcg=True, do_cm=True):
    session = _make_session()
    # print_id -> { source_name: {p, c, u, s} }
    prints_out = {}

    def add(print_id, source, price, currency, url, in_stock):
        prints_out.setdefault(print_id, {})[source] = {
            "p": round(float(price), 2),
            "c": currency,
            "u": url,
            "s": bool(in_stock),
        }

    if do_shopify:
        stores = [
            ShopifyStore("MinMaxGames", "https://www.minmaxgames.com", "AUD", session),
            ShopifyStore("Fluke & Box", "https://www.flukeandbox.com", "NZD", session),
        ]
        for store in stores:
            try:
                store.crawl()
                hits = 0
                for pr in prints:
                    res = store.price_for(pr)
                    if res:
                        add(pr.id, store.name, res[0], store.currency, res[1], res[2])
                        hits += 1
                sys.stderr.write(f"[{store.name}] matched {hits} prints\n")
            except Exception as e:  # noqa: BLE001
                sys.stderr.write(f"[{store.name}] failed: {e}\n")

    if do_tcg:
        try:
            for pid, (price, url, stock) in scrape_tcgplayer(prints, session).items():
                add(pid, "TCGplayer", price, "USD", url, stock)
        except Exception as e:  # noqa: BLE001
            sys.stderr.write(f"[TCGplayer] failed: {e}\n")

    if do_cm:
        try:
            for pid, (price, url, stock) in scrape_cardmarket(prints, session).items():
                add(pid, "Cardmarket", price, "EUR", url, stock)
        except Exception as e:  # noqa: BLE001
            sys.stderr.write(f"[Cardmarket] failed: {e}\n")

    return prints_out


def main(argv):
    ap = argparse.ArgumentParser(description="Scrape FAB prices -> prices.json")
    ap.add_argument("--from", dest="src", default=DEFAULT_CARD_JSON,
                    help="card.json path or URL")
    ap.add_argument("--out", dest="out", default=DEFAULT_OUT_DIR,
                    help="output directory (writes prices.json into it)")
    ap.add_argument("--limit", dest="limit", type=int, default=None)
    ap.add_argument("--no-shopify", action="store_true")
    ap.add_argument("--no-tcg", action="store_true")
    ap.add_argument("--no-cm", action="store_true")
    args = ap.parse_args(argv)

    prints = load_prints(args.src, args.limit)
    sys.stderr.write(f"Loaded {len(prints)} prints from {args.src}\n")

    fx = fetch_fx()
    prints_out = build(
        prints,
        do_shopify=not args.no_shopify,
        do_tcg=not args.no_tcg,
        do_cm=not args.no_cm,
    )

    payload = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": _dt.datetime.now(_dt.timezone.utc)
            .replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "prints": prints_out,
    }
    if fx:
        payload["fx"] = fx

    os.makedirs(args.out, exist_ok=True)
    out_path = os.path.join(args.out, "prices.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, separators=(",", ":"), ensure_ascii=False)

    priced = len(prints_out)
    sys.stderr.write(f"Wrote {out_path}: {priced} prints priced "
                     f"(of {len(prints)}), fx={'yes' if fx else 'no'}\n")


if __name__ == "__main__":
    main(sys.argv[1:])
