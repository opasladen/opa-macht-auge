/// On-Device-OCR fuer Pokemon-Karten via Google ML Kit (Latin-Skript).
///
/// Liest aus dem aufgenommenen Foto die folgenden Felder, sofern sichtbar:
///   - [CardCode.number]        z. B. "111"
///   - [CardCode.printedTotal]  z. B. 195   (aus "111/195")
///   - [CardCode.language]      "en" wenn `HP` sichtbar, "de" wenn `KP` sichtbar
///   - [CardCode.setCode]       moderne Karten tragen 3-Letter-Codes wie
///                              `BLK`, `SVI`, `PAR` neben dem Sprachkuerzel
///
/// Strategie: gesamtes Bild OCR-en, Treffer per Regex einsammeln. Fuer den
/// Server-Lookup reichen meist 2 Felder (number + language oder
/// number + printedTotal). Wenn die OCR nichts brauchbares liefert,
/// faellt die Scan-Pipeline auf den DINOv2-Embedder zurueck.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

class CardCode {
  const CardCode({
    this.number,
    this.printedTotal,
    this.language,
    this.setCode,
  });

  final String? number;
  final int? printedTotal;
  final String? language; // "en" | "de"
  final String? setCode;

  /// Mindestens [number] + ein weiteres Feld -> Server-Lookup lohnt sich.
  bool get isUseful =>
      number != null &&
      (language != null || printedTotal != null || setCode != null);

  @override
  String toString() =>
      'CardCode(number=$number, total=$printedTotal, lang=$language, set=$setCode)';
}

class OcrService {
  OcrService(this._recognizer);

  final TextRecognizer _recognizer;

  static const _numberTotalPattern = r'(\d{1,3})\s*/\s*(\d{1,3})';
  static const _hpPattern = r'\b\d{1,3}\s*HP\b';
  static const _kpPattern = r'\b\d{1,3}\s*KP\b';
  // 3-Letter-Set-Code direkt vor EN/DE auf modernen Karten,
  // z. B. "BLK · EN", "SVI · DE". Bullet/Mittelpunkt ist ZWINGEND, sonst
  // matched das Pattern fälschlicherweise Wortenden wie GENERATIONS -> EN.
  static const _setLangPattern = r'\b([A-Z]{3})\s*[·•⋅・]\s*(EN|DE)\b';

  /// Liest einen Datei-Pfad, OCR-t das gesamte Bild und parsed die Felder.
  Future<CardCode?> extractFromFile(String imagePath) async {
    final input = InputImage.fromFilePath(imagePath);
    final result = await _recognizer.processImage(input);
    // Diagnose: roher OCR-Text in einer Zeile, damit wir Fehlinterpretationen
    // im logcat nachvollziehen koennen.
    final flat = result.text.replaceAll('\n', ' ¶ ');
    // ignore: avoid_print
    print('[OCR] raw="$flat"');
    return _parse(result.text);
  }

  CardCode? _parse(String fullText) {
    if (fullText.trim().isEmpty) return null;
    final text = fullText.replaceAll('\n', ' ');

    String? number;
    int? printedTotal;
    final numTotalMatch = RegExp(_numberTotalPattern).firstMatch(text);
    if (numTotalMatch != null) {
      number = numTotalMatch.group(1);
      printedTotal = int.tryParse(numTotalMatch.group(2) ?? '');
    }

    String? language;
    if (RegExp(_kpPattern).hasMatch(text)) {
      language = 'de';
    } else if (RegExp(_hpPattern).hasMatch(text)) {
      language = 'en';
    }

    String? setCode;
    final setLangMatch = RegExp(_setLangPattern).firstMatch(text);
    if (setLangMatch != null) {
      setCode = setLangMatch.group(1);
      // Falls HP/KP nichts ergab, zieht die Sprache aus dem Set-Tag.
      language ??= (setLangMatch.group(2) ?? '').toLowerCase();
    }

    if (number == null && language == null && setCode == null && printedTotal == null) {
      return null;
    }
    return CardCode(
      number: number,
      printedTotal: printedTotal,
      language: language,
      setCode: setCode,
    );
  }

  void dispose() {
    _recognizer.close();
  }
}

final ocrServiceProvider = Provider<OcrService>((ref) {
  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  final service = OcrService(recognizer);
  ref.onDispose(service.dispose);
  return service;
});
