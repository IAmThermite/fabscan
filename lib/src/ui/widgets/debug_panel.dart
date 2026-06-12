import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../models/scan_debug_info.dart';
import '../../vision/phash.dart';

/// Collapsible diagnostics for how the current card was recognised — modelled
/// on the "Detection signals". Shows the matched pHash
/// arm (the "detect method"), Hamming distances, OCR text and the deskewed
/// capture that was hashed.
class DebugPanel extends StatelessWidget {
  const DebugPanel({super.key, required this.debug});

  final ScanDebugInfo debug;

  // Per-arm accent colours, matching the reference panel.
  static const Map<String, Color> _armColors = {
    'art': Color(0xFF88CCFF),
    'full': Color(0xFF99DD99),
    'title': Color(0xFFFFCC66),
  };

  Color _armColor(String arm) => _armColors[arm] ?? Colors.white70;

  static Color _pitchColor(int pitch) => switch (pitch) {
        1 => const Color(0xFFE57373), // red
        2 => const Color(0xFFFFD54F), // yellow
        3 => const Color(0xFF64B5F6), // blue
        _ => Colors.white70,
      };

  static String _pitchLabel(int pitch, double? confidence) {
    final name = switch (pitch) {
      1 => 'red (1)',
      2 => 'yellow (2)',
      3 => 'blue (3)',
      _ => 'unknown ($pitch)',
    };
    if (confidence == null) return name;
    return '$name  ${(confidence * 100).toStringAsFixed(0)}%';
  }

  @override
  Widget build(BuildContext context) {
    final armColor = _armColor(debug.matchedArm);
    return Theme(
      // Keep the divider lines subtle inside the tile.
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        leading: const Icon(Icons.bug_report_outlined),
        title: const Text('Scan debug'),
        subtitle: Row(
          children: [
            _ArmChip(arm: debug.matchedArm, color: armColor),
            const SizedBox(width: 8),
            Text('dist ${debug.distance}/${debug.threshold}'),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          if (debug.capturedCardPng != null) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _CropPreview(
                  png: debug.capturedCardPng,
                  label: 'full',
                  height: 200,
                  color: _armColor('full'),
                ),
                const SizedBox(width: 12),
                _CropPreview(
                  png: debug.capturedArtPng,
                  label: 'art',
                  height: 92,
                  color: _armColor('art'),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          if (debug.capturedTitleRawPng != null ||
              debug.capturedTitleOcrPng != null) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Title OCR → ${debug.usedOcr ? '"${debug.ocrTitle}"' : '(nothing read)'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 4),
            _TitlePreview(png: debug.capturedTitleRawPng, label: 'raw'),
            const SizedBox(height: 6),
            _TitlePreview(png: debug.capturedTitleOcrPng, label: 'OCR input'),
            const SizedBox(height: 12),
          ],
          if (debug.detectSource != null)
            _Signal(label: 'Detect source', value: debug.detectSource),
          _Signal(
            label: 'Matched arm',
            child: _ArmChip(arm: debug.matchedArm, color: armColor),
          ),
          _Signal(
            label: 'Hamming distance',
            value: '${debug.distance}  (threshold ${debug.threshold})',
            valueColor: armColor,
          ),
          if (debug.detectorScore != null)
            _Signal(
              label: 'Detector score',
              value: debug.detectorScore!.toStringAsFixed(3),
            ),
          _Signal(
            label: 'OCR title',
            value: debug.usedOcr ? '"${debug.ocrTitle}"' : 'none',
          ),
          if (debug.ocrConfidence != null)
            _Signal(
              label: 'OCR confidence',
              value: debug.ocrConfidence!.toStringAsFixed(0),
              valueColor:
                  debug.matchedArm == 'title' ? _armColor('title') : null,
            ),
          if (debug.detectedPitch != null)
            _Signal(
              label: 'Pitch',
              value: _pitchLabel(debug.detectedPitch!, debug.pitchConfidence),
              valueColor: _pitchColor(debug.detectedPitch!),
            ),
          const Divider(height: 24),
          _HashRow(
            label: 'art',
            query: debug.queryArt,
            matched: debug.matchedArtPhash,
            color: _armColor('art'),
          ),
          _HashRow(
            label: 'full',
            query: debug.queryFull,
            matched: debug.matchedFullPhash,
            color: _armColor('full'),
          ),
          if (debug.candidates.length > 1) ...[
            const Divider(height: 24),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Candidates',
                  style: Theme.of(context).textTheme.labelLarge),
            ),
            const SizedBox(height: 4),
            for (final c in debug.candidates)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    _ArmChip(arm: c.arm, color: _armColor(c.arm), small: true),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(c.faceId,
                          style: const TextStyle(fontFamily: 'monospace')),
                    ),
                    Text('dist ${c.distance}'),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// A wide, full-width title-strip preview (the title bar is short and wide).
class _TitlePreview extends StatelessWidget {
  const _TitlePreview({required this.png, required this.label});

  final Uint8List? png;
  final String label;

  @override
  Widget build(BuildContext context) {
    if (png == null) return const SizedBox.shrink();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 64,
          child: Text(label, style: Theme.of(context).textTheme.labelSmall),
        ),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white24),
              borderRadius: BorderRadius.circular(4),
              color: Colors.white10,
            ),
            clipBehavior: Clip.antiAlias,
            child: Image.memory(
              png!,
              height: 44,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          ),
        ),
      ],
    );
  }
}

/// A labelled, bordered crop preview used in the captures row.
class _CropPreview extends StatelessWidget {
  const _CropPreview({
    required this.png,
    required this.label,
    required this.height,
    required this.color,
  });

  final Uint8List? png;
  final String label;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: png != null
              ? Image.memory(png!, height: height, gaplessPlayback: true)
              : Container(
                  height: height,
                  width: height * 0.7,
                  color: Colors.white10,
                  alignment: Alignment.center,
                  child: const Icon(Icons.image_not_supported_outlined, size: 18),
                ),
        ),
        const SizedBox(height: 2),
        _ArmChip(arm: label, color: color, small: true),
      ],
    );
  }
}

class _Signal extends StatelessWidget {
  const _Signal({required this.label, this.value, this.valueColor, this.child});

  final String label;
  final String? value;
  final Color? valueColor;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            flex: 3,
            child: child ??
                Text(
                  value ?? '',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                    color: valueColor,
                  ),
                ),
          ),
        ],
      ),
    );
  }
}

/// Shows the query vs matched hash for one arm, with their Hamming distance.
class _HashRow extends StatelessWidget {
  const _HashRow({
    required this.label,
    required this.query,
    required this.matched,
    required this.color,
  });

  final String label;
  final int? query;
  final int? matched;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final dist = (query != null && matched != null)
        ? PHash.hammingDistance(query!, matched!)
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _ArmChip(arm: label, color: color, small: true),
              const Spacer(),
              if (dist != null)
                Text('Δ $dist', style: TextStyle(color: color, fontWeight: FontWeight.w600)),
            ],
          ),
          Text('query:   ${query ?? '—'}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
          Text('matched: ${matched ?? '—'}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
        ],
      ),
    );
  }
}

class _ArmChip extends StatelessWidget {
  const _ArmChip({required this.arm, required this.color, this.small = false});

  final String arm;
  final Color color;
  final bool small;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: small ? 6 : 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        arm,
        style: TextStyle(
          color: color,
          fontFamily: 'monospace',
          fontSize: small ? 11 : 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
