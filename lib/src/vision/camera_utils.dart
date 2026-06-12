import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

/// A single YUV plane, reduced to the plain, isolate-sendable fields the NV21
/// repack needs (the raw bytes plus the strides). [CameraImage]'s own plane
/// objects aren't sendable across isolates, so we copy these out on the root
/// isolate before handing a frame to the CV worker.
class CameraPlane {
  const CameraPlane(this.bytes, this.bytesPerRow, this.bytesPerPixel);

  final Uint8List bytes;
  final int bytesPerRow;
  final int? bytesPerPixel;
}

/// An isolate-sendable snapshot of a camera frame: just the plane bytes and
/// geometry. Build one from a [CameraImage] on the root isolate via
/// [CameraFrame.fromCameraImage], then send it to the CV worker.
class CameraFrame {
  const CameraFrame({
    required this.width,
    required this.height,
    required this.planes,
  });

  final int width;
  final int height;
  final List<CameraPlane> planes;

  /// Snapshots [image] into a sendable [CameraFrame], or returns null for an
  /// unexpected (non-YUV420) format.
  static CameraFrame? fromCameraImage(CameraImage image) {
    if (image.format.group != ImageFormatGroup.yuv420) return null;
    return CameraFrame(
      width: image.width,
      height: image.height,
      planes: [
        for (final p in image.planes)
          CameraPlane(p.bytes, p.bytesPerRow, p.bytesPerPixel),
      ],
    );
  }
}

/// Converts a [CameraImage] from the camera stream into a BGR OpenCV [cv.Mat].
/// Convenience wrapper around [cameraFrameToBgr] for the inline (non-isolate)
/// path. The caller owns the returned Mat and must dispose it.
cv.Mat? cameraImageToBgr(CameraImage image) {
  final frame = CameraFrame.fromCameraImage(image);
  if (frame == null) return null; // Unexpected format — handled elsewhere.
  return cameraFrameToBgr(frame);
}

/// Converts a [CameraFrame] into a BGR OpenCV [cv.Mat].
///
/// Both platforms stream YUV420, but with different chroma layouts: Android
/// delivers YUV_420_888 (3 planes — separate U and V), iOS delivers
/// 420YpCbCr8BiPlanar (2 planes — Y plus one interleaved CbCr plane). We repack
/// either into NV21 (Y plane followed by interleaved V/U) and let OpenCV convert
/// to BGR. The caller owns the returned Mat and must dispose it.
cv.Mat cameraFrameToBgr(CameraFrame frame) {
  final nv21 = _yuv420ToNv21(frame);
  final width = frame.width;
  final height = frame.height;

  // NV21 buffer is height*1.5 rows of `width` bytes, single channel.
  final yuvMat = cv.Mat.fromList(
    height + height ~/ 2,
    width,
    cv.MatType.CV_8UC1,
    nv21,
  );
  try {
    return cv.cvtColor(yuvMat, cv.COLOR_YUV2BGR_NV21);
  } finally {
    yuvMat.dispose();
  }
}

Uint8List _yuv420ToNv21(CameraFrame image) {
  final width = image.width;
  final height = image.height;
  final yPlane = image.planes[0];

  final chromaWidth = width ~/ 2;
  final chromaHeight = height ~/ 2;
  final out = Uint8List(width * height + 2 * chromaWidth * chromaHeight);

  var idx = 0;
  // Y plane, honouring row stride padding.
  final yRowStride = yPlane.bytesPerRow;
  for (var row = 0; row < height; row++) {
    final start = row * yRowStride;
    out.setRange(idx, idx + width, yPlane.bytes, start);
    idx += width;
  }

  // Chroma, packed as interleaved V,U (NV21 ordering). Android exposes U and V
  // as separate planes ([1] and [2]); iOS exposes a single interleaved CbCr
  // plane ([1], no [2]) where each pixel is [Cb, Cr] == [U, V].
  if (image.planes.length >= 3) {
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    final uvRowStride = uPlane.bytesPerRow;
    final uvPixelStride = uPlane.bytesPerPixel ?? 1;
    for (var row = 0; row < chromaHeight; row++) {
      for (var col = 0; col < chromaWidth; col++) {
        final uvIndex = row * uvRowStride + col * uvPixelStride;
        out[idx++] = vPlane.bytes[uvIndex];
        out[idx++] = uPlane.bytes[uvIndex];
      }
    }
  } else {
    final uvPlane = image.planes[1];
    final uvRowStride = uvPlane.bytesPerRow;
    final uvPixelStride = uvPlane.bytesPerPixel ?? 2;
    for (var row = 0; row < chromaHeight; row++) {
      for (var col = 0; col < chromaWidth; col++) {
        final uvIndex = row * uvRowStride + col * uvPixelStride;
        out[idx++] = uvPlane.bytes[uvIndex + 1]; // V (Cr)
        out[idx++] = uvPlane.bytes[uvIndex]; // U (Cb)
      }
    }
  }
  return out;
}
