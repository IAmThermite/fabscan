import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/fab_card.dart';
import '../../pricing/pricing_service.dart';

/// Fetches and displays pricing for [print] across all configured sources.
class PricePanel extends StatefulWidget {
  const PricePanel({super.key, required this.card, required this.print});

  final FabCard card;
  final CardPrint print;

  @override
  State<PricePanel> createState() => _PricePanelState();
}

class _PricePanelState extends State<PricePanel> {
  late Future<List<SourceQuotes>> _future;

  @override
  void initState() {
    super.initState();
    final pricing = context.read<PricingService>();
    _future = pricing.fetchAll(widget.card, widget.print);
  }

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<SourceQuotes>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final results = snapshot.data ?? const <SourceQuotes>[];
        return Column(
          children: [
            for (final r in results)
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
    final priced = result.quotes.where((q) => q.price != null).length;

    final subtitle = result.error
        ? 'Couldn\'t reach source'
        : hasLivePrice
            ? '$priced listing${priced == 1 ? '' : 's'} · from ${cheapest.displayPrice}'
            : 'Tap to view on ${result.source.name}';

    // The URL to open: cheapest listing if we have one, else the search page.
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
