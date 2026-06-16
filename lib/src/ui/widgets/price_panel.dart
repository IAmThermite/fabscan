import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/remote_update_service.dart';
import '../../models/fab_card.dart';
import '../../pricing/currency.dart';
import '../../pricing/pricing_service.dart';

/// Displays cached pricing for [print] across all configured sources, converted
/// to the user's chosen display currency, with the dataset's freshness and a
/// live "checking for updates" indicator. Sources without a stored price (and
/// the whole panel when offline with no data) fall back to a link-out.
class PricePanel extends StatefulWidget {
  const PricePanel({super.key, required this.card, required this.print});

  final FabCard card;
  final CardPrint print;

  @override
  State<PricePanel> createState() => _PricePanelState();
}

class _PricePanelState extends State<PricePanel> {
  late Future<PriceResult> _future;
  RemoteUpdateService? _updates;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final updates = context.read<RemoteUpdateService>();
    if (!identical(updates, _updates)) {
      _updates?.pricesUpdatedTick.removeListener(_reload);
      _updates = updates..pricesUpdatedTick.addListener(_reload);
    }
  }

  Future<PriceResult> _load() =>
      context.read<PricingService>().quotesFor(widget.card, widget.print);

  void _reload() {
    if (mounted) setState(() => _future = _load());
  }

  Future<void> _setCurrency(String currency) async {
    await context.read<PricingService>().setDisplayCurrency(currency);
    _reload();
  }

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  void dispose() {
    _updates?.pricesUpdatedTick.removeListener(_reload);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PriceResult>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final result = snapshot.data;
        final sources = result?.sources ?? const [];
        return Column(
          children: [
            _Header(
              generatedAt: result?.generatedAt,
              currency: result?.displayCurrency ?? supportedDisplayCurrencies.first,
              onCurrencyChanged: _setCurrency,
              refreshing: _updates?.refreshing,
            ),
            for (final r in sources)
              _SourceTile(
                result: r,
                card: widget.card,
                print: widget.print,
                onOpen: _open,
              ),
          ],
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.generatedAt,
    required this.currency,
    required this.onCurrencyChanged,
    required this.refreshing,
  });

  final DateTime? generatedAt;
  final String currency;
  final ValueChanged<String> onCurrencyChanged;
  final ValueListenable<bool>? refreshing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stale = generatedAt != null &&
        DateTime.now().difference(generatedAt!) > const Duration(hours: 48);
    final freshness = generatedAt == null
        ? 'Live prices unavailable offline'
        : 'Updated ${_ago(generatedAt!)}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(
        children: [
          const Text('Prices in '),
          DropdownButton<String>(
            value: supportedDisplayCurrencies.contains(currency)
                ? currency
                : supportedDisplayCurrencies.first,
            isDense: true,
            underline: const SizedBox.shrink(),
            onChanged: (c) {
              if (c != null) onCurrencyChanged(c);
            },
            items: [
              for (final c in supportedDisplayCurrencies)
                DropdownMenuItem(value: c, child: Text(c)),
            ],
          ),
          const Spacer(),
          if (refreshing != null)
            ValueListenableBuilder<bool>(
              valueListenable: refreshing!,
              builder: (context, busy, _) => busy
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 6),
                        Text('Checking…', style: theme.textTheme.labelSmall),
                      ],
                    )
                  : Text(
                      freshness,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: stale ? theme.colorScheme.tertiary : null,
                      ),
                    ),
            )
          else
            Text(freshness, style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    return '${(d.inDays / 7).floor()}w ago';
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.result,
    required this.card,
    required this.print,
    required this.onOpen,
  });

  final SourceQuotes result;
  final FabCard card;
  final CardPrint print;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final cheapest = result.cheapest;
    final hasLivePrice = cheapest != null;

    final subtitle = hasLivePrice
        ? (cheapest.originalDisplayPrice != null
            ? 'from ${cheapest.displayPrice} (${cheapest.originalDisplayPrice})'
            : 'from ${cheapest.displayPrice}')
        : 'Tap to view on ${result.source.name}';

    // The URL to open: stored listing if we have one, else the search page.
    final url = hasLivePrice
        ? cheapest.url
        : (result.quotes.isNotEmpty
            ? result.quotes.first.url
            : result.source.searchUrl(card, print));

    return ListTile(
      leading: CircleAvatar(child: Text(result.source.name.characters.first)),
      title: Text(result.source.name),
      subtitle: Text(subtitle),
      trailing: hasLivePrice
          ? Text(
              cheapest.displayPrice,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
            )
          : const Icon(Icons.open_in_new, size: 18),
      onTap: () => onOpen(url),
    );
  }
}
