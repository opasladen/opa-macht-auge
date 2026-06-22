/// Image-Preprocessing nach dinov2_small.preprocess.json.
///
/// Muss EXAKT der HF AutoImageProcessor-Logik aus
/// `ml/ml/embedder/export_onnx.py` entsprechen, sonst weichen die
/// Embeddings vom Index ab.
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

class PreprocessConfig {
  PreprocessConfig({
    required this.imageMean,
    required this.imageStd,
    required this.resizeShortestEdge,
    required this.cropHeight,
    required this.cropWidth,
    required this.rescaleFactor,
    required this.doResize,
    required this.doCenterCrop,
  });

  final List<double> imageMean;
  final List<double> imageStd;
  final int resizeShortestEdge;
  final int cropHeight;
  final int cropWidth;
  final double rescaleFactor;
  final bool doResize;
  final bool doCenterCrop;

  factory PreprocessConfig.fromJson(Map<String, dynamic> json) =>
      PreprocessConfig(
        imageMean: (json['image_mean'] as List<dynamic>).cast<num>().map((e) => e.toDouble()).toList(),
        imageStd: (json['image_std'] as List<dynamic>).cast<num>().map((e) => e.toDouble()).toList(),
        resizeShortestEdge: json['resize_shortest_edge'] as int,
        cropHeight: json['crop_height'] as int,
        cropWidth: json['crop_width'] as int,
        rescaleFactor: (json['rescale_factor'] as num).toDouble(),
        doResize: json['do_resize'] as bool? ?? true,
        doCenterCrop: json['do_center_crop'] as bool? ?? true,
      );
}

/// Liefert einen Float32List in NCHW-Layout [1, 3, H, W] mit Werten
/// (pixel * rescale - mean) / std.
Float32List preprocessImage(img.Image source, PreprocessConfig cfg) {
  img.Image work = source;

  // 1) Resize shortest_edge (aspect ratio bleibt erhalten).
  if (cfg.doResize) {
    final w = work.width;
    final h = work.height;
    final scale = cfg.resizeShortestEdge / (w < h ? w : h);
    final newW = (w * scale).round();
    final newH = (h * scale).round();
    work = img.copyResize(
      work,
      width: newW,
      height: newH,
      interpolation: img.Interpolation.cubic,
    );
  }

  // 2) Center-Crop auf crop_height x crop_width.
  if (cfg.doCenterCrop) {
    final left = ((work.width - cfg.cropWidth) ~/ 2).clamp(0, work.width);
    final top = ((work.height - cfg.cropHeight) ~/ 2).clamp(0, work.height);
    work = img.copyCrop(
      work,
      x: left,
      y: top,
      width: cfg.cropWidth,
      height: cfg.cropHeight,
    );
  }

  // 3) Normalize + transpose HWC -> CHW.
  final h = cfg.cropHeight;
  final w = cfg.cropWidth;
  final out = Float32List(1 * 3 * h * w);
  final meanR = cfg.imageMean[0];
  final meanG = cfg.imageMean[1];
  final meanB = cfg.imageMean[2];
  final stdR = cfg.imageStd[0];
  final stdG = cfg.imageStd[1];
  final stdB = cfg.imageStd[2];
  final rescale = cfg.rescaleFactor;
  final planeSize = h * w;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final pixel = work.getPixel(x, y);
      final r = pixel.r * rescale;
      final g = pixel.g * rescale;
      final b = pixel.b * rescale;
      final idx = y * w + x;
      out[idx] = (r - meanR) / stdR;
      out[planeSize + idx] = (g - meanG) / stdG;
      out[2 * planeSize + idx] = (b - meanB) / stdB;
    }
  }
  return out;
}
