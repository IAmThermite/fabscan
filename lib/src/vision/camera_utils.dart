import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

/// Converts a [CameraImage] from the camera stream into a BGR OpenCV [cv.Mat].
///
/// Both platforms stream YUV420, but with different chroma layouts: Android
/// delivers YUV_420_888 (3 planes — separate U and V), iOS delivers
/// 420YpCbCr8BiPlanar (2 planes — Y plus one interleaved CbCr plane). We repack
/// either into NV21 (Y plane followed by interleaved V/U) and let OpenCV convert
/// to BGR. The caller owns the returned Mat and must dispose it.
cv.Mat? cameraImageToBgr(CameraImage image) {
  if (image.format.group != ImageFormatGroup.yuv420) {
    return null; // Unexpected format — handled elsewhere.
  }
  final nv21 = _yuv420ToNv21(image);
  final width = image.width;
  final height = image.height;

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

Uint8List _yuv420ToNv21(CameraImage image) {
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
