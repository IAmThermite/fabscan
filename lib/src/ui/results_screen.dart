import 'package:flutter/material.dart';

import '../models/fab_card.dart';
import '../models/scan_debug_info.dart';
import 'widgets/debug_panel.dart';
import 'widgets/price_panel.dart';

/// Shows the matched card large, its set/foil/art variants in a carousel, and
/// live pricing for the currently selected variant.
class ResultsScreen extends StatefulWidget {
  const ResultsScreen({
    super.key,
    required this.card,
    required this.initialPrint,
    this.debug,
  });

  final FabCard card;
  final CardPrint initialPrint;

  /// Scan diagnostics, present only when arriving from a live scan (null when
  /// opened from the recents list).
  final ScanDebugInfo? debug;

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  late CardPrint _selected = widget.initialPrint;

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    return Scaffold(
      appBar: AppBar(title: Text(card.name)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _CardHero(print: _selected),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(card.name, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  children: [
                    if (card.pitch != null) _Chip('Pitch ${card.pitch}'),
                    _Chip(_selected.variantLabel),
                  ],
                ),
              ],
            ),
          ),
          if (card.prints.length > 1) ...[
            const _SectionTitle('Variants'),
            _VariantCarousel(
              prints: card.prints,
              selected: _selected,
              onSelect: (p) => setState(() => _selected = p),
            ),
          ],
          const _SectionTitle('Prices'),
          // Re-mount the panel when the variant changes so it refetches.
          PricePanel(key: ValueKey(_selected.id), card: card, print: _selected),
          if (widget.debug != null) ...[
            const SizedBox(height: 8),
            DebugPanel(debug: widget.debug!),
          ],
        ],
      ),
    );
  }
}

class _CardHero extends StatelessWidget {
  const _CardHero({required this.print});
  final CardPrint print;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 360,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: print.imageUrl == null
          ? const _NoImage()
          : ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.network(
                print.imageUrl!,
                fit: BoxFit.contain,
                loadingBuilder: (c, child, progress) => progress == null
                    ? child
                    : const Center(child: CircularProgressIndicator()),
                errorBuilder: (c, e, s) => const _NoImage(),
              ),
            ),
    );
  }
}

class _VariantCarousel extends StatelessWidget {
  const _VariantCarousel({
    required this.prints,
    required this.selected,
    required this.onSelect,
  });

  final List<CardPrint> prints;
  final CardPrint selected;
  final ValueChanged<CardPrint> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 150,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: prints.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final p = prints[i];
          final isSelected = p.id == selected.id;
          return GestureDetector(
            onTap: () => onSelect(p),
            child: Column(
              children: [
                Container(
                  width: 80,
                  height: 112,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : Colors.transparent,
                      width: 3,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: p.imageUrl == null
                      ? const _NoImage()
                      : Image.network(p.imageUrl!, fit: BoxFit.cover,
                          errorBuilder: (c, e, s) => const _NoImage()),
                ),
                const SizedBox(height: 4),
                SizedBox(
                  width: 84,
                  child: Text(
                    p.variantLabel,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );
}

class _Chip extends StatelessWidget {
  const _Chip(this.label);
  final String label;

  @override
  Widget build(BuildContext context) =>
      Chip(label: Text(label), visualDensity: VisualDensity.compact);
}

class _NoImage extends StatelessWidget {
  const _NoImage();

  @override
  Widget build(BuildContext context) => Container(
        color: Colors.white10,
        alignment: Alignment.center,
        child: const Icon(Icons.image_not_supported_outlined),
      );
}
