/// DTO fuer eine erkannte Karte im Kamerabild.
library;

import 'dart:math' as math;
import 'dart:ui' show Offset;

/// Eine Detection: 4 Eckpunkte (Pixel-Koordinaten im Original-Bild,
/// im Uhrzeigersinn beginnend Top-Left), Confidence, Rotationswinkel in Rad.
class CardDetection {
  CardDetection({
    required this.polygon,
    required this.confidence,
    required this.angleRad,
    required this.center,
    required this.width,
    required this.height,
  });

  /// 4 Eckpunkte in Original-Bild-Pixel-Koordinaten.
  /// Reihenfolge: top-left, top-right, bottom-right, bottom-left
  /// (relativ zur Karten-Orientierung, nicht zum Bild).
  final List<Offset> polygon;

  /// Class-Confidence aus YOLO (0..1).
  final double confidence;

  /// Rotation der Karte im Bild, Radian.
  final double angleRad;

  /// Bounding-Box-Center im Original-Bild.
  final Offset center;

  /// Karten-Breite und -Hoehe in Original-Bild-Pixeln (vor Rotation).
  final double width;
  final double height;

  /// Axis-Aligned Bounding Box der 4 Eckpunkte. Praktisch fuer einfache
  /// Visualisierungs-Overlays oder als Fallback-Crop.
  ({double left, double top, double right, double bottom}) get aabb {
    var minX = polygon.first.dx;
    var minY = polygon.first.dy;
    var maxX = minX;
    var maxY = minY;
    for (final p in polygon) {
      minX = math.min(minX, p.dx);
      minY = math.min(minY, p.dy);
      maxX = math.max(maxX, p.dx);
      maxY = math.max(maxY, p.dy);
    }
    return (left: minX, top: minY, right: maxX, bottom: maxY);
  }

  @override
  String toString() =>
      'CardDetection(conf=${confidence.toStringAsFixed(3)}, '
      'angle=${(angleRad * 180 / math.pi).toStringAsFixed(1)}°, '
      'size=${width.toStringAsFixed(0)}x${height.toStringAsFixed(0)})';
}
