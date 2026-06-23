// app/lib/embedder/camera_image_converter.dart
/// Schneller Konverter: ``CameraImage`` (YUV_420_888) direkt in den
/// preprocessierten Float32-Tensor fuer den ONNX-Embedder, ohne den Umweg
/// ueber JPEG-Encode/Decode oder das ``image`` Package.
///
/// Wir kombinieren in einem einzigen Pass:
///   * 90\u00b0 Rotation (Pixel-Backkamera = sensorOrientation=90)
///   * Center-Crop auf den quadratischen Karten-ROI
///   * Bilineares Resize auf 224\u00d7224
///   * YUV \u2192 RGB (BT.601)
///   * Normalisierung mit ImageNet-Mean/Std
///   * Transpose HWC \u2192 CHW (Float32List in [1,3,H,W])
///
/// Performance-Ziel: <30 ms auf einem Pixel 8 Pro fuer 1280\u00d7720-Frames.
library;

import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

import 'preprocess.dart';

/// Resultat einer Frame-Konvertierung. ``tensor`` ist NCHW [1,3,h,w] und
/// kann direkt an [EmbedderService.embedTensor] weitergereicht werden;
/// ``sharpness`` ist die Laplace-Varianz \u00fcber eine grobe Y-Sub-Sampling
/// und dient als billiges Gate bevor wir das teure ONNX laufen lassen.
class PreprocessedFrame {
  PreprocessedFrame({required this.tensor, required this.sharpness});
  final Float32List tensor;
  final double sharpness;
}

/// Konvertiert einen Kamera-Frame in den fertigen Embedder-Input.
///
/// [sensorOrientation] gibt an, um wieviel Grad das Sensor-Buffer im
/// Uhrzeigersinn rotiert werden muss, damit es in der nat\u00fcrlichen
/// Device-Orientierung steht (typischer Pixel-Backkamera-Wert: 90).
PreprocessedFrame preprocessCameraImage(
  CameraImage image,
  PreprocessConfig cfg, {
  int sensorOrientation = 90,
}) {
  if (image.format.group != ImageFormatGroup.yuv420) {
    throw ArgumentError(
      'preprocessCameraImage erwartet YUV_420_888, bekam ${image.format.group}',
    );
  }
  if (image.planes.length < 3) {
    throw ArgumentError(
      'YUV-Frame muss 3 Planes haben, hat ${image.planes.length}',
    );
  }

  final outW = cfg.cropWidth;
  final outH = cfg.cropHeight;

  final yPlane = image.planes[0];
  final uPlane = image.planes[1];
  final vPlane = image.planes[2];
  final yBytes = yPlane.bytes;
  final uBytes = uPlane.bytes;
  final vBytes = vPlane.bytes;
  final yRowStride = yPlane.bytesPerRow;
  final uRowStride = uPlane.bytesPerRow;
  final vRowStride = vPlane.bytesPerRow;
  // Bei semi-planar (NV21/NV12) ist pixelStride=2, bei I420 = 1.
  final uPixelStride = uPlane.bytesPerPixel ?? 1;
  final vPixelStride = vPlane.bytesPerPixel ?? 1;

  final imageW = image.width;
  final imageH = image.height;

  // Display-Koordinaten nach Rotation (sensorOrientation=90 oder 270 dreht).
  final rotated = sensorOrientation == 90 || sensorOrientation == 270;
  final viewW = rotated ? imageH : imageW;
  final viewH = rotated ? imageW : imageH;

  // Karten-Aspect-Ratio Crop: Pokemon-Karten sind 245x337 hochkant. Der
  // alte image-Package-Pfad hat genauso gecroppt, ein quadratischer Crop
  // schliesst zu viel Hintergrund links/rechts der Karte mit ein und das
  // DINOv2-Embedding mittelt diesen Hintergrund mit ein -> Treffer-Sim
  // faellt um ~10 Prozentpunkte.
  const cardAspect = 245.0 / 337.0; // width / height
  final shortAxis = viewW < viewH ? viewW : viewH;
  var roiH = (shortAxis * 0.95).toInt();
  var roiW = (roiH * cardAspect).toInt();
  if (roiW > viewW) {
    roiW = viewW;
    roiH = (roiW / cardAspect).toInt();
  }
  if (roiH > viewH) {
    roiH = viewH;
    roiW = (roiH * cardAspect).toInt();
  }
  final roiLeftView = (viewW - roiW) ~/ 2;
  final roiTopView = (viewH - roiH) ~/ 2;

  // Normalisierungs-Konstanten (vorberechnet, hot loop wird so winzig wie
  // moeglich gehalten).
  final meanR = cfg.imageMean[0];
  final meanG = cfg.imageMean[1];
  final meanB = cfg.imageMean[2];
  final stdR = cfg.imageStd[0];
  final stdG = cfg.imageStd[1];
  final stdB = cfg.imageStd[2];
  final rescale = cfg.rescaleFactor;
  final invStdR = 1.0 / stdR;
  final invStdG = 1.0 / stdG;
  final invStdB = 1.0 / stdB;

  final out = Float32List(3 * outH * outW);
  final planeSize = outH * outW;

  // Nearest-Neighbour Resize: ROI ist rechteckig (Karten-Aspect), also
  // brauchen wir separate Skalierung in X und Y.
  final scaleX = roiW / outW;
  final scaleY = roiH / outH;

  for (var oy = 0; oy < outH; oy++) {
    final syViewF = roiTopView + (oy + 0.5) * scaleY - 0.5;
    final syViewI = syViewF < 0
        ? 0
        : (syViewF >= viewH ? viewH - 1 : syViewF.toInt());

    for (var ox = 0; ox < outW; ox++) {
      final sxViewF = roiLeftView + (ox + 0.5) * scaleX - 0.5;
      final sxViewI = sxViewF < 0
          ? 0
          : (sxViewF >= viewW ? viewW - 1 : sxViewF.toInt());

      // Mapping View -> Sensor je nach Rotation. Wir verwenden Nearest-
      // Neighbour: bei 1080p/720p -> 224 ist das Sampling 3-5x downsample,
      // bilinear wuerde Faktor 4 langsamer ohne sichtbaren Qualitaetsgewinn
      // fuer DINOv2 sein.
      final int srcX;
      final int srcY;
      switch (sensorOrientation) {
        case 90:
          srcX = syViewI;
          srcY = imageH - 1 - sxViewI;
          break;
        case 270:
          srcX = imageW - 1 - syViewI;
          srcY = sxViewI;
          break;
        case 180:
          srcX = imageW - 1 - sxViewI;
          srcY = imageH - 1 - syViewI;
          break;
        default:
          srcX = sxViewI;
          srcY = syViewI;
      }

      // Y-Sample.
      final y = yBytes[srcY * yRowStride + srcX] & 0xff;

      // U/V werden subsampled (4:2:0). Wir lesen den Chroma-Pixel des 2x2
      // Macro-Blocks der unseren Luma-Pixel enthaelt.
      final uvY = srcY >> 1;
      final uvX = srcX >> 1;
      final u = uBytes[uvY * uRowStride + uvX * uPixelStride] & 0xff;
      final v = vBytes[uvY * vRowStride + uvX * vPixelStride] & 0xff;

      // BT.601 YUV -> RGB. (Y is 0..255 already, no offset.)
      final cb = u - 128;
      final cr = v - 128;
      final rTmp = y + 1.402 * cr;
      final gTmp = y - 0.344136 * cb - 0.714136 * cr;
      final bTmp = y + 1.772 * cb;

      final rClamped = rTmp < 0 ? 0.0 : (rTmp > 255 ? 255.0 : rTmp);
      final gClamped = gTmp < 0 ? 0.0 : (gTmp > 255 ? 255.0 : gTmp);
      final bClamped = bTmp < 0 ? 0.0 : (bTmp > 255 ? 255.0 : bTmp);

      final r = rClamped * rescale;
      final g = gClamped * rescale;
      final b = bClamped * rescale;

      final idx = oy * outW + ox;
      out[idx] = (r - meanR) * invStdR;
      out[planeSize + idx] = (g - meanG) * invStdG;
      out[2 * planeSize + idx] = (b - meanB) * invStdB;
    }
  }

  // Sharpness ueber die Y-Plane: 32x32 Subsampling, 4-Nachbarn-Laplace.
  final sharpness = _ySharpness(yBytes, imageW, imageH, yRowStride);

  return PreprocessedFrame(tensor: out, sharpness: sharpness);
}

/// Laplace-Varianz auf der Y-Plane, downsampled auf 32x32 fuer Geschwindigkeit.
double _ySharpness(Uint8List y, int w, int h, int rowStride) {
  const samples = 32;
  final stepX = (w / samples).floor().clamp(1, w);
  final stepY = (h / samples).floor().clamp(1, h);
  final cols = (w / stepX).floor();
  final rows = (h / stepY).floor();
  if (cols < 3 || rows < 3) return 0;
  final gray = Uint8List(cols * rows);
  for (var ry = 0; ry < rows; ry++) {
    final sy = ry * stepY;
    for (var rx = 0; rx < cols; rx++) {
      final sx = rx * stepX;
      gray[ry * cols + rx] = y[sy * rowStride + sx];
    }
  }
  var sum = 0.0;
  var sumSq = 0.0;
  var count = 0;
  for (var ry = 1; ry < rows - 1; ry++) {
    for (var rx = 1; rx < cols - 1; rx++) {
      final c = gray[ry * cols + rx];
      final l = gray[ry * cols + (rx - 1)];
      final r = gray[ry * cols + (rx + 1)];
      final t = gray[(ry - 1) * cols + rx];
      final b = gray[(ry + 1) * cols + rx];
      final lap = (l + r + t + b - 4 * c).toDouble();
      sum += lap;
      sumSq += lap * lap;
      count++;
    }
  }
  if (count == 0) return 0;
  final mean = sum / count;
  return (sumSq / count) - mean * mean;
}

/// Konvertiert einen ``CameraImage`` (YUV_420_888) in ein ``img.Image``
/// (RGB), heruntergerechnet auf eine Ziel-Laengkante (typ. 640 fuer den
/// YOLO-Detector). Wendet die Sensor-Rotation an, damit das resultierende
/// Bild bereits in Display-Orientierung steht.
///
/// Nearest-Neighbour-Sampling. Auf einem Pixel 8 Pro fuer 1280x720 ->
/// 640x360 typisch ~10-20 ms. Bewusst kein bilinear: YOLOv11n-OBB ist
/// robust gegen leichte Aliasing-Artefakte und wir wollen die zusaetzliche
/// Latenz minimieren.
img.Image yuvToRgbDownscaled(
  CameraImage image, {
  int targetLongEdge = 640,
  int sensorOrientation = 90,
}) {
  if (image.format.group != ImageFormatGroup.yuv420) {
    throw ArgumentError(
      'yuvToRgbDownscaled erwartet YUV_420_888, bekam ${image.format.group}',
    );
  }
  if (image.planes.length < 3) {
    throw ArgumentError(
      'YUV-Frame muss 3 Planes haben, hat ${image.planes.length}',
    );
  }

  final yPlane = image.planes[0];
  final uPlane = image.planes[1];
  final vPlane = image.planes[2];
  final yBytes = yPlane.bytes;
  final uBytes = uPlane.bytes;
  final vBytes = vPlane.bytes;
  final yRowStride = yPlane.bytesPerRow;
  final uRowStride = uPlane.bytesPerRow;
  final vRowStride = vPlane.bytesPerRow;
  final uPixelStride = uPlane.bytesPerPixel ?? 1;
  final vPixelStride = vPlane.bytesPerPixel ?? 1;

  final imageW = image.width;
  final imageH = image.height;

  // Display-Koordinaten nach Rotation.
  final rotated = sensorOrientation == 90 || sensorOrientation == 270;
  final viewW = rotated ? imageH : imageW;
  final viewH = rotated ? imageW : imageH;

  // Aspect-erhaltender Downscale auf targetLongEdge.
  final longEdge = viewW > viewH ? viewW : viewH;
  final scale = longEdge > targetLongEdge ? targetLongEdge / longEdge : 1.0;
  final dstW = (viewW * scale).round();
  final dstH = (viewH * scale).round();

  // numChannels: 3 erzwingen. Default ist 4 (RGBA) und kann auf
  // bestimmten Pixel-Format-Pfaden eine unmodifiable Palette-Buffer-View
  // liefern -> setPixelRgb wirft 'Cannot modify an unmodifiable list'.
  final out = img.Image(width: dstW, height: dstH, numChannels: 3);
  final invScale = 1.0 / scale;

  for (var dy = 0; dy < dstH; dy++) {
    final syView = (dy * invScale).toInt();
    for (var dx = 0; dx < dstW; dx++) {
      final sxView = (dx * invScale).toInt();

      // Mapping View -> Sensor je nach Rotation.
      final int srcX;
      final int srcY;
      switch (sensorOrientation) {
        case 90:
          srcX = syView;
          srcY = imageH - 1 - sxView;
          break;
        case 270:
          srcX = imageW - 1 - syView;
          srcY = sxView;
          break;
        case 180:
          srcX = imageW - 1 - sxView;
          srcY = imageH - 1 - syView;
          break;
        default:
          srcX = sxView;
          srcY = syView;
      }

      final yi = yBytes[srcY * yRowStride + srcX] & 0xff;
      final uvY = srcY >> 1;
      final uvX = srcX >> 1;
      final u = uBytes[uvY * uRowStride + uvX * uPixelStride] & 0xff;
      final v = vBytes[uvY * vRowStride + uvX * vPixelStride] & 0xff;

      final cb = u - 128;
      final cr = v - 128;
      var r = (yi + 1.402 * cr).round();
      var g = (yi - 0.344136 * cb - 0.714136 * cr).round();
      var b = (yi + 1.772 * cb).round();
      if (r < 0) r = 0; else if (r > 255) r = 255;
      if (g < 0) g = 0; else if (g > 255) g = 255;
      if (b < 0) b = 0; else if (b > 255) b = 255;

      out.setPixelRgb(dx, dy, r, g, b);
    }
  }
  return out;
}
