#!/usr/bin/env python3
"""Scrapes current prices for every print in ``card.json`` and writes a single
``prices.json`` the FabScan app downloads (≤1x/24h) and serves offline.

Sources (each isolated — one failing never aborts the run):
  * MinMaxGames and Fluke & Box: Shopify storefronts. We crawl each store's
    public ``/products.json`` once and join products/variants to prints by
    collector number — MinMaxGames tags each product with its set code + number,
    Fluke & Box puts it in each variant's SKU (prints with no number match fall
    back to fuzzy name matching). Currency is not assumed: it's read from each
    store's ``/meta.json`` (with a presentment-prices fallback), since a Shopify
    catalogue's prices are in the shop's own base currency.
  * TCGplayer (USD): per-print, via the product id embedded in each print's
    ``tcgplayer_url`` and TCGplayer's own ``mpapi`` price-points endpoint.

Cardmarket is intentionally NOT scraped: it sits behind a Cloudflare managed
challenge that neither TLS impersonation nor a headless browser clears reliably
(and never from a datacenter/CI IP), so the app just deep-links out to it (see
``LinkOutSource.cardmarket`` in lib/src/pricing/sources/link_out_source.dart).

Pick which sources to scrape with ``--only`` / ``--skip`` (comma-separated site
slugs: ``minmaxgames``, ``flukeandbox``, ``tcgplayer``; the alias ``shopify``
expands to the two Shopify stores). With neither flag, all run.

Prices are stored in each source's own currency; the app converts at view time
using the ``fx`` block (rates fetched once from a free, no-key API).

The per-source keys in the output MUST byte-match the app's ``PriceSource.name``
values: ``MinMaxGames``, ``Fluke & Box``, ``TCGplayer``. A mismatch silently
downgrades that source to a link-out in the app.

Output (short keys keep the file small; only prints with >=1 price are included):
  { "schema_version": 1, "generated_at": "ISO8601",
    "fx": {"base":"USD","as_of":"YYYY-MM-DD","rates":{...}},
    "prints": { "<unique_id>": { "MinMaxGames": {"p":12.5,"c":"AUD","u":"...","s":true} } } }

Usage:
  python tool/scrape_prices.py [--from <card.json|url>] [--out dist/] [--limit N]
                               [--only minmaxgames,tcgplayer] [--skip flukeandbox]
                               [--shopify-debug]
  # legacy aliases (still honoured): --no-shopify --no-tcg
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

# Scrapeable site slugs, selected with --only / --skip. Order is run order.
ALL_SITES = ("minmaxgames", "flukeandbox", "tcgplayer")

# Friendly aliases accepted by --only / --skip. "shopify" expands to both stores.
_SITE_ALIASES = {
    "minmax": "minmaxgames", "minmaxgames": "minmaxgames",
    "fluke": "flukeandbox", "flukebox": "flukeandbox", "flukeandbox": "flukeandbox",
    "tcg": "tcgplayer", "tcgplayer": "tcgplayer",
}


def _expand_site(token):
    """One --only/--skip token -> set of canonical site slugs."""
    t = re.sub(r"[^a-z0-9]", "", token.lower())
    if t == "shopify":
        return {"minmaxgames", "flukeandbox"}
    if t in _SITE_ALIASES:
        return {_SITE_ALIASES[t]}
    raise SystemExit(
        f"Unknown site '{token}'. Choose from: {', '.join(ALL_SITES)} "
        f"(or the alias 'shopify').")


def _parse_site_list(spec):
    out = set()
    for tok in (spec or "").split(","):
        if tok.strip():
            out |= _expand_site(tok)
    return out


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

    __slots__ = ("id", "name", "norm_name", "set_id", "number",
                 "foiling", "edition", "art_variations", "tcgplayer_url")

    def __init__(self, card, pr):
        self.id = pr["unique_id"]
        self.name = card["name"]
        self.norm_name = normalize(card["name"])
        self.set_id = (pr.get("set_id") or "").strip()
        # Collector number, set code + number (e.g. "MST095") — the (set, number)
        # key the Shopify number join uses. NB this is card.json's per-print
        # ``id``, distinct from ``unique_id`` (stored above as ``self.id``).
        self.number = (pr.get("id") or "").strip()
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
#
# Both stores are Shopify and expose their whole catalogue at /products.json.
# We join a print to a product/variant by its **collector number** — set code +
# number, which is exactly card.json's per-print ``id`` (e.g. "MST131"). That's
# far more precise than the card name (no fuzzy title scoring, no confusing two
# cards that share a name). Where the number lives differs per store:
#   * MinMaxGames (minmaxgamesfab.com) tags each product with its set code +
#     number as a ``tags`` entry (match mode "tags").
#   * Fluke & Box puts the set code + number in each variant's ``sku``
#     (match mode "sku").
# A raw tag/sku token is resolved to a (SET, number) pair only when its prefix
# is one of the set codes we actually have, so the exact token format (case,
# separators, zero-padding) doesn't matter. Prints
# with no number match fall back to fuzzy name matching (the previous behaviour),
# so a store that doesn't tag/sku the way we expect degrades gracefully rather
# than dropping to zero matches.
#
# Currency is NOT hard-coded. /products.json prices are in the shop's base
# currency, which we read from the store's public /meta.json (and, failing that,
# infer from a variant's ``presentment_prices``), falling back to a configured
# default only if both are unavailable. The app converts to the user's display
# currency at view time, so the important thing is that each stored price
# carries the *correct* currency tag.

# Art-variation -> words that tend to appear in a product title (name fallback).
_ART_WORDS = {
    "EA": ["extended art", "extended"],
    "FA": ["full art", "full"],
    "AA": ["alternate art", "alt art"],
    "AB": ["alternate border", "borderless"],
    "AT": ["alternate text"],
}

_NON_ALNUM = re.compile(r"[^A-Za-z0-9]+")


def _split_set_number(token, valid_codes, code_lengths):
    """A raw token ('MST131', 'mst-131', '1HB001') -> ('MST', 131) when its
    prefix is a known set code and the rest is a number, else None.

    Matched against ``valid_codes`` (uppercase set codes we actually have) so the
    token's format is irrelevant; ``code_lengths`` is those codes' lengths,
    longest first, so 'PSM' wins over a hypothetical 'PS'."""
    t = _NON_ALNUM.sub("", token or "").upper()
    if not t:
        return None
    for length in code_lengths:
        code = t[:length]
        rest = t[length:]
        if code in valid_codes and rest.isdigit():
            return (code, int(rest))
    return None


def _print_number_key(pr):
    """('MST', 131) for a print whose ``number`` is 'MST131', else None."""
    s = (pr.number or "").upper()
    code = pr.set_id.upper()
    if code and s.startswith(code):
        s = s[len(code):]
    m = re.search(r"\d+", s)
    if not (code and m):
        return None
    return (code, int(m.group(0)))


def _better(a, b):
    """Pick the better of two index entries (in-stock beats out-of-stock, then
    cheaper wins). Either may be None."""
    if a is None:
        return b
    if b is None:
        return a
    if a["available"] != b["available"]:
        return a if a["available"] else b
    return a if a["price"] <= b["price"] else b


class ShopifyStore:
    """Crawls a store's public catalogue and matches prints to product prices.

    ``match`` selects the precise join: "tags" reads the set code + number from
    each product's ``tags``; "sku" reads it from each variant's ``sku``. Either
    way unmatched prints fall back to fuzzy name matching. ``currency`` is
    resolved from the store during :meth:`crawl` (see the section comment)."""

    def __init__(self, name, base_url, session, *, default_currency,
                 valid_codes, match="tags", debug=False):
        self.name = name
        self.base_url = base_url.rstrip("/")
        self.session = session
        self.default_currency = default_currency
        self.currency = default_currency  # refined in crawl()
        self.valid_codes = valid_codes
        self.code_lengths = sorted({len(c) for c in valid_codes}, reverse=True)
        self.match = match
        self.debug = debug
        self.by_number = {}  # (SET, num) -> {price, url, available}
        self.products = []   # name-fallback: {norm_title, url, price, available}
        self._presentment_currency = None

    # -- currency ----------------------------------------------------------- #
    def _meta_currency(self):
        """The shop's base currency from /meta.json, or None."""
        try:
            r = self.session.get(f"{self.base_url}/meta.json", timeout=20)
            if r.status_code == 200:
                cur = (r.json() or {}).get("currency")
                if isinstance(cur, str) and len(cur) == 3:
                    return cur.upper()
        except Exception:  # noqa: BLE001
            pass
        return None

    def _note_presentment(self, variants):
        """Record the base currency from a variant's ``presentment_prices`` (the
        entry whose amount equals the variant ``price``), as a meta.json fallback."""
        if self._presentment_currency:
            return
        for v in variants:
            try:
                base = float(v.get("price"))
            except (TypeError, ValueError):
                continue
            for pp in (v.get("presentment_prices") or []):
                price = (pp or {}).get("price") or {}
                code = price.get("currency_code")
                try:
                    amount = float(price.get("amount"))
                except (TypeError, ValueError):
                    continue
                if code and abs(amount - base) < 0.005:
                    self._presentment_currency = code.upper()
                    return

    # -- crawl -------------------------------------------------------------- #
    def crawl(self):
        meta_currency = self._meta_currency()
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

        self.currency = (meta_currency or self._presentment_currency
                         or self.default_currency)
        src = ("meta.json" if meta_currency else
               "presentment_prices" if self._presentment_currency else "default")
        sys.stderr.write(
            f"[{self.name}] indexed {total} products "
            f"({len(self.by_number)} by number, {len(self.products)} by name), "
            f"currency {self.currency} (from {src})\n")
        if self.debug:
            for key in list(self.by_number)[:8]:
                ent = self.by_number[key]
                sys.stderr.write(f"[{self.name}]   {key[0]}{key[1]} -> "
                                 f"{ent['price']} {self.currency} "
                                 f"(avail={ent['available']})\n")

    def _index_product(self, p):
        handle = p.get("handle") or ""
        product_url = (f"{self.base_url}/products/{handle}"
                       if handle else self.base_url)
        variants = p.get("variants") or []
        self._note_presentment(variants)

        if self.match == "sku":
            self._index_by_sku(variants, product_url)
        else:
            self._index_by_tags(p, variants, product_url)
        # Always keep a name entry too, for prints the number join misses.
        self._index_by_name(p, variants, product_url)

    def _index_by_tags(self, p, variants, product_url):
        keys = self._number_keys(self._tags(p))
        if not keys:
            return
        chosen = self._cheapest(variants)
        if chosen is None:
            return
        price, available = chosen
        entry = {"price": price, "url": product_url, "available": available}
        for key in keys:
            self.by_number[key] = _better(self.by_number.get(key), entry)

    def _index_by_sku(self, variants, product_url):
        for v in variants:
            key = self._number_key(v.get("sku"))
            if key is None:
                continue
            try:
                price = float(v.get("price"))
            except (TypeError, ValueError):
                continue
            vid = v.get("id")
            url = f"{product_url}?variant={vid}" if vid else product_url
            entry = {"price": price, "url": url, "available": bool(v.get("available"))}
            self.by_number[key] = _better(self.by_number.get(key), entry)

    def _index_by_name(self, p, variants, product_url):
        chosen = self._cheapest(variants)
        if chosen is None:
            return
        price, available = chosen
        self.products.append({
            "norm_title": normalize(p.get("title") or ""),
            "url": product_url,
            "price": price,
            "available": available,
        })

    # -- helpers ------------------------------------------------------------ #
    @staticmethod
    def _tags(p):
        """``tags`` as a list (Shopify serves an array via /products.json, but a
        comma string via the Admin API — accept both)."""
        tags = p.get("tags")
        if isinstance(tags, str):
            return [t.strip() for t in tags.split(",") if t.strip()]
        return list(tags or [])

    @staticmethod
    def _cheapest(variants):
        """(cheapest price, in_stock) for a product. Prefers in-stock variants,
        falls back to the cheapest of any. None when nothing is priced."""
        avail, any_ = [], []
        for v in variants:
            try:
                price = float(v.get("price"))
            except (TypeError, ValueError):
                continue
            any_.append(price)
            if v.get("available"):
                avail.append(price)
        if avail:
            return (min(avail), True)
        if any_:
            return (min(any_), False)
        return None

    def _number_key(self, token):
        return _split_set_number(token, self.valid_codes, self.code_lengths)

    def _number_keys(self, tokens):
        out = set()
        for tok in tokens:
            key = self._number_key(tok)
            if key is not None:
                out.add(key)
        return out

    # -- lookup ------------------------------------------------------------- #
    def price_for(self, pr):
        """Best match for a print -> (price, url, in_stock) or None. Tries the
        precise collector-number join first, then fuzzy name matching."""
        key = _print_number_key(pr)
        if key is not None:
            ent = self.by_number.get(key)
            if ent is not None:
                return (ent["price"], ent["url"], ent["available"])
        return self._price_by_name(pr)

    def _price_by_name(self, pr):
        if not pr.norm_name:
            return None
        set_tok = normalize(pr.set_id)
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
# Assembly
# --------------------------------------------------------------------------- #

def _make_session():
    s = requests.Session()
    s.headers.update({"User-Agent": USER_AGENT, "Accept": "application/json"})
    return s


# Shopify stores keyed by site slug. Each scrapes independently. The tuple is
# (display name, storefront origin, fallback currency, match mode):
#   * match "tags" reads the collector number from each product's ``tags``,
#   * match "sku"  reads it from each variant's ``sku``.
# The fallback currency is used only if a store's currency can't be detected
# from /meta.json or presentment prices. MinMaxGames uses its FAB-specific
# storefront (minmaxgamesfab.com), whose products are tagged per set.
_SHOPIFY_STORES = {
    "minmaxgames": ("MinMaxGames", "https://minmaxgamesfab.com", "AUD", "tags"),
    "flukeandbox": ("Fluke & Box", "https://www.flukeandbox.com", "NZD", "sku"),
}


def build(prints, enabled, *, shopify_debug=False):
    """Scrape the ``enabled`` set of site slugs. ``enabled`` is a subset of
    ``ALL_SITES``; each source is isolated so one failing never aborts the run."""
    session = _make_session()
    # Set codes we actually have — the vocabulary the Shopify number join matches
    # tags/skus against.
    valid_codes = {p.set_id.upper() for p in prints if p.set_id}
    # print_id -> { source_name: {p, c, u, s} }
    prints_out = {}

    def add(print_id, source, price, currency, url, in_stock):
        prints_out.setdefault(print_id, {})[source] = {
            "p": round(float(price), 2),
            "c": currency,
            "u": url,
            "s": bool(in_stock),
        }

    for slug, (name, base_url, currency, match) in _SHOPIFY_STORES.items():
        if slug not in enabled:
            continue
        try:
            store = ShopifyStore(name, base_url, session,
                                 default_currency=currency, valid_codes=valid_codes,
                                 match=match, debug=shopify_debug)
            store.crawl()
            hits = 0
            for pr in prints:
                res = store.price_for(pr)
                if res:
                    add(pr.id, store.name, res[0], store.currency, res[1], res[2])
                    hits += 1
            sys.stderr.write(f"[{store.name}] matched {hits} prints\n")
        except Exception as e:  # noqa: BLE001
            sys.stderr.write(f"[{name}] failed: {e}\n")

    if "tcgplayer" in enabled:
        try:
            for pid, (price, url, stock) in scrape_tcgplayer(prints, session).items():
                add(pid, "TCGplayer", price, "USD", url, stock)
        except Exception as e:  # noqa: BLE001
            sys.stderr.write(f"[TCGplayer] failed: {e}\n")

    return prints_out


def resolve_sites(args):
    """Final set of enabled site slugs from --only / --skip and the legacy
    --no-* flags. --only sets the base allowlist; --skip and --no-* remove."""
    enabled = _parse_site_list(args.only) if args.only else set(ALL_SITES)
    if args.skip:
        enabled -= _parse_site_list(args.skip)
    if args.no_shopify:
        enabled -= {"minmaxgames", "flukeandbox"}
    if args.no_tcg:
        enabled.discard("tcgplayer")
    return enabled


def main(argv):
    ap = argparse.ArgumentParser(description="Scrape FAB prices -> prices.json")
    ap.add_argument("--from", dest="src", default=DEFAULT_CARD_JSON,
                    help="card.json path or URL")
    ap.add_argument("--out", dest="out", default=DEFAULT_OUT_DIR,
                    help="output directory (writes prices.json into it)")
    ap.add_argument("--limit", dest="limit", type=int, default=None)
    ap.add_argument("--only", help="comma-separated sites to scrape: "
                    + ", ".join(ALL_SITES) + " (alias: shopify)")
    ap.add_argument("--skip", help="comma-separated sites to skip")
    ap.add_argument("--shopify-debug", action="store_true",
                    help="log per-store currency detection and sample collector-"
                         "number matches from the Shopify catalogues")
    # Legacy aliases (kept working; --only/--skip are preferred).
    ap.add_argument("--no-shopify", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--no-tcg", action="store_true", help=argparse.SUPPRESS)
    args = ap.parse_args(argv)

    enabled = resolve_sites(args)
    if not enabled:
        sys.stderr.write("No sites enabled (check --only/--skip). Nothing to do.\n")
        return
    sys.stderr.write("Scraping: "
                     + ", ".join(s for s in ALL_SITES if s in enabled) + "\n")

    prints = load_prints(args.src, args.limit)
    sys.stderr.write(f"Loaded {len(prints)} prints from {args.src}\n")

    fx = fetch_fx()
    prints_out = build(prints, enabled, shopify_debug=args.shopify_debug)

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
