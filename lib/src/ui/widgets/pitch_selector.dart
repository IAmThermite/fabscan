import 'package:flutter/material.dart';

import '../../models/pitch_variants.dart';

/// A row of coloured circles — one per pitch variation of a card — that the
/// user taps to flick between the red (1), yellow (2) and blue (3) versions.
class PitchSelector extends StatelessWidget {
  const PitchSelector({
    super.key,
    required this.variants,
    required this.selectedPitch,
    required this.onSelect,
  });

  final List<PitchVariant> variants;
  final int selectedPitch;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          for (final v in variants)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: _PitchDot(
                pitch: v.pitch,
                selected: v.pitch == selectedPitch,
                onTap: () => onSelect(v.pitch),
              ),
            ),
        ],
      ),
    );
  }
}

class _PitchDot extends StatelessWidget {
  const _PitchDot({
    required this.pitch,
    required this.selected,
    required this.onTap,
  });

  final int pitch;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = pitchColor(pitch);
    return Semantics(
      button: true,
      selected: selected,
      label: 'Pitch ${pitchName(pitch)} ($pitch)',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: selected ? 44 : 34,
          height: selected ? 44 : 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? Colors.white : Colors.white24,
              width: selected ? 3 : 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.6),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Text(
            '$pitch',
            style: TextStyle(
              color: Colors.black87,
              fontWeight: FontWeight.bold,
              fontSize: selected ? 17 : 13,
            ),
          ),
        ),
      ),
    );
  }
}

/// FAB pitch colours (1 = red, 2 = yellow, 3 = blue), matching the debug panel.
Color pitchColor(int pitch) => switch (pitch) {
      1 => const Color(0xFFE57373),
      2 => const Color(0xFFFFD54F),
      3 => const Color(0xFF64B5F6),
      _ => const Color(0xFFB0BEC5),
    };

String pitchName(int pitch) => switch (pitch) {
      1 => 'red',
      2 => 'yellow',
      3 => 'blue',
      _ => 'unknown',
    };
