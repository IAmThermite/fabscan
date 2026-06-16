import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/card_repository.dart';
import '../models/fab_card.dart';
import '../models/pitch_variants.dart';
import '../models/scan_debug_info.dart';
import 'widgets/debug_panel.dart';
import 'widgets/pitch_selector.dart';
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
  // The currently shown pitch-card and one of its prints. Both start at the
  // recognised card and may switch when the user picks another pitch.
  late FabCard _card = widget.card;
  late CardPrint _selected = widget.initialPrint;
  PitchVariantSet? _pitches;

  @override
  void initState() {
    super.initState();
    _loadPitchVariants();
  }

  Future<void> _loadPitchVariants() async {
    final set = await context
        .read<CardRepository>()
        .pitchVariants(widget.card, widget.initialPrint);
    if (!mounted) return;
    setState(() {
      _pitches = set;
      // Snap to the matched pitch's representative within the chosen set (a
      // no-op when the scanned set already holds the pitch options).
      final v = set.byPitch(widget.card.pitch ?? -1);
      if (set.hasMultiple && v != null) {
        _card = v.card;
        _selected = v.print;
      }
    });
  }

  void _selectPitch(int pitch) {
    final v = _pitches?.byPitch(pitch);
    if (v == null) return;
    setState(() {
      _card = v.card;
      _selected = v.print;
    });
  }

  /// Step to the previous/next print of the current card, wrapping around.
  void _stepPrint(int delta) {
    final prints = _card.prints;
    if (prints.length < 2) return;
    final i = prints.indexWhere((p) => p.id == _selected.id);
    final next = ((i < 0 ? 0 : i) + delta) % prints.length;
    setState(() => _selected = prints[(next + prints.length) % prints.length]);
  }

  @override
  Widget build(BuildContext context) {
    final card = _card;
    final pitches = _pitches;
    return Scaffold(
      appBar: AppBar(title: Text(card.name)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _CardHero(
            print: _selected,
            canStep: card.prints.length > 1,
            onStep: _stepPrint,
          ),
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
          if (pitches != null && pitches.hasMultiple) ...[
            const _SectionTitle('Pitch'),
            PitchSelector(
              variants: pitches.variants,
              selectedPitch: card.pitch ?? pitches.variants.first.pitch,
              onSelect: _selectPitch,
            ),
          ],
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
  const _CardHero({
    required this.print,
    this.canStep = false,
    this.onStep,
  });

  final CardPrint print;

  /// Whether the prev/next print arrows should be shown.
  final bool canStep;

  /// Called with -1 (previous) or +1 (next) when an arrow is tapped.
  final ValueChanged<int>? onStep;

  @override
  Widget build(BuildContext context) {
    final image = print.imageUrl == null
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
          );
    return SizedBox(
      height: 360,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 56),
            child: image,
          ),
          if (canStep) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: _StepButton(
                icon: Icons.chevron_left,
                onPressed: () => onStep?.call(-1),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: _StepButton(
                icon: Icons.chevron_right,
                onPressed: () => onStep?.call(1),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Material(
        color: Colors.black.withValues(alpha: 0.4),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: IconButton(
          icon: Icon(icon),
          color: Colors.white,
          onPressed: onPressed,
          tooltip: icon == Icons.chevron_left ? 'Previous print' : 'Next print',
        ),
      ),
    );
  }
}

class _VariantCarousel extends StatefulWidget {
  const _VariantCarousel({
    required this.prints,
    required this.selected,
    required this.onSelect,
  });

  final List<CardPrint> prints;
  final CardPrint selected;
  final ValueChanged<CardPrint> onSelect;

  @override
  State<_VariantCarousel> createState() => _VariantCarouselState();
}

class _VariantCarouselState extends State<_VariantCarousel> {
  // Approx width of a thumbnail (80) + its separator (12); used to bring the
  // selected item roughly into view when stepped via the hero arrows.
  static const double _itemExtent = 92;
  final _controller = ScrollController();

  @override
  void didUpdateWidget(_VariantCarousel old) {
    super.didUpdateWidget(old);
    if (old.selected.id != widget.selected.id) _scrollToSelected();
  }

  void _scrollToSelected() {
    final i = widget.prints.indexWhere((p) => p.id == widget.selected.id);
    if (i < 0 || !_controller.hasClients) return;
    final target = (i * _itemExtent)
        .clamp(0.0, _controller.position.maxScrollExtent);
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prints = widget.prints;
    return SizedBox(
      height: 150,
      child: ListView.separated(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: prints.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final p = prints[i];
          final isSelected = p.id == widget.selected.id;
          return GestureDetector(
            onTap: () => widget.onSelect(p),
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
