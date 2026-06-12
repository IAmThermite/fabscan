import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/card_repository.dart';
import '../db/recents_store.dart';
import '../scan/scan_controller.dart';
import '../vision/scan_config.dart';
import 'recents_screen.dart';
import 'results_screen.dart';
import 'widgets/card_overlay_painter.dart';

/// The home screen: a live camera view that continuously hunts for a card.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> with WidgetsBindingObserver {
  late final ScanController _controller;
  bool _navigating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = ScanController(
      repository: context.read<CardRepository>(),
      recents: context.read<RecentsStore>(),
    )..addListener(_onControllerChanged);
    _controller.initialize();
  }

  void _onControllerChanged() {
    if (_controller.state == ScanState.matched &&
        _controller.result != null &&
        !_navigating) {
      _openResult();
    }
  }

  Future<void> _openResult() async {
    _navigating = true;
    final result = _controller.result!;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ResultsScreen(
          card: result.card,
          initialPrint: result.matchedPrint,
          debug: result.debug,
        ),
      ),
    );
    _navigating = false;
    await _controller.resume();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _controller.handleAppPaused();
      case AppLifecycleState.resumed:
        _controller.handleAppResumed();
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FabScan'),
        actions: [
          IconButton(
            tooltip: 'Recently scanned',
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const RecentsScreen()),
            ),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    switch (_controller.state) {
      case ScanState.initializing:
        return const Center(child: CircularProgressIndicator());
      case ScanState.noCamera:
        return const _Message(
          icon: Icons.no_photography,
          text: 'No camera available on this device.',
        );
      case ScanState.permissionDenied:
        return const _Message(
          icon: Icons.lock,
          text: 'Camera permission denied.\nEnable it in system settings to scan.',
        );
      case ScanState.error:
        return _Message(
          icon: Icons.error_outline,
          text: 'Camera error:\n${_controller.errorMessage ?? 'unknown'}',
        );
      case ScanState.scanning:
      case ScanState.processing:
      case ScanState.matched:
        return _buildPreview(context);
    }
  }

  /// Full-screen camera preview with cover fit (preserves aspect, no stretch),
  /// so the alignment guide painted over it maps to the frame accurately.
  Widget _coverPreview(CameraController cam) {
    final preview = cam.value.previewSize;
    if (preview == null) return CameraPreview(cam);
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: preview.height, // portrait width
          height: preview.width, // portrait height
          child: CameraPreview(cam),
        ),
      ),
    );
  }

  /// The four corners of the capture rectangle in upright-frame pixel space.
  List<Offset> _guideQuad(int uprightW, int uprightH) {
    final (x, y, w, h) = ScanConfig.captureRect(uprightW, uprightH);
    return [
      Offset(x.toDouble(), y.toDouble()),
      Offset((x + w).toDouble(), y.toDouble()),
      Offset((x + w).toDouble(), (y + h).toDouble()),
      Offset(x.toDouble(), (y + h).toDouble()),
    ];
  }

  Widget _buildPreview(BuildContext context) {
    final cam = _controller.camera;
    if (cam == null || !cam.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    // Upright (portrait) frame dimensions, used to place the guide so it lines
    // up exactly with the region CardDetector.captureGuideRegion will crop.
    final preview = cam.value.previewSize;
    final guideQuad = preview == null
        ? null
        : _guideQuad(preview.height.round(), preview.width.round());

    return Stack(
      fit: StackFit.expand,
      children: [
        _coverPreview(cam),
        // Fixed alignment guide (matches the guide-region crop exactly).
        if (guideQuad != null)
          CustomPaint(
            painter: CardOverlayPainter(
              quad: guideQuad,
              frameSize: Size(preview!.height, preview.width),
              quarterTurns: 0,
              color: Colors.white.withValues(alpha: 0.55),
            ),
          ),
        // Detected contour outline + status pill. These update every sampled
        // frame, so they listen to the overlay notifier directly rather than
        // rebuilding the whole preview (camera view + guide) on each frame.
        ValueListenableBuilder<ScanOverlay>(
          valueListenable: _controller.overlay,
          builder: (context, overlay, _) {
            final detecting = overlay.quad != null;
            final color = detecting ? Colors.greenAccent : Colors.white70;
            return Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(
                  painter: CardOverlayPainter(
                    quad: overlay.quad,
                    frameSize: overlay.frameSize,
                    quarterTurns: (cam.description.sensorOrientation ~/ 90),
                    color: color,
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 24,
                  child: Center(
                    child: _StatusPill(
                      state: _controller.state,
                      detecting: detecting,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        if (_controller.state == ScanState.matched)
          const Center(child: CircularProgressIndicator()),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.state, required this.detecting});

  final ScanState state;
  final bool detecting;

  @override
  Widget build(BuildContext context) {
    final (label, icon) = switch (state) {
      ScanState.matched => ('Card found!', Icons.check_circle),
      _ when detecting => ('Hold steady…', Icons.center_focus_strong),
      _ => ('Point at a card', Icons.search),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48),
            const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
