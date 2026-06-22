/// Persistenter Scan-Verlauf + Sammlung als JSON-Datei im App-Documents-
/// Verzeichnis. Wir nutzen JSON statt SQLite weil wir fuer V1 sowieso unter
/// 10k Eintraegen bleiben und Drift mit den aktuellen Versionen
/// inkompatibel ist (siehe Memory). Atomare Writes via tmp+rename.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'scan_history_entry.dart';

const String _kFilename = 'scan_history.json';

/// Liefert den Datei-Pfad zur Verlaufs-JSON.
Future<File> _historyFile() async {
  final dir = await getApplicationDocumentsDirectory();
  return File(p.join(dir.path, _kFilename));
}

class ScanHistoryStore {
  ScanHistoryStore();

  /// Laedt den gesamten Verlauf von Disk. Bei nicht-existierendem File:
  /// leere Liste. Bei korruptem JSON: ebenfalls leere Liste (besser als
  /// die App nicht zu starten).
  Future<List<ScanHistoryEntry>> load() async {
    final file = await _historyFile();
    if (!file.existsSync()) return const [];
    try {
      final content = await file.readAsString();
      if (content.trim().isEmpty) return const [];
      final raw = jsonDecode(content);
      if (raw is! List) return const [];
      return raw
          .whereType<Map<String, dynamic>>()
          .map(ScanHistoryEntry.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Atomarer Save: schreibt in `<file>.tmp` und rename'd dann. Damit kein
  /// halb-geschriebenes File entsteht falls die App in der Mitte stirbt.
  Future<void> save(List<ScanHistoryEntry> entries) async {
    final file = await _historyFile();
    final tmp = File('${file.path}.tmp');
    final encoded = const JsonEncoder.withIndent('  ')
        .convert(entries.map((e) => e.toJson()).toList());
    await tmp.writeAsString(encoded, flush: true);
    if (file.existsSync()) {
      await file.delete();
    }
    await tmp.rename(file.path);
  }
}

final scanHistoryStoreProvider = Provider<ScanHistoryStore>((ref) {
  return ScanHistoryStore();
});

/// AsyncNotifier ueber den Verlauf. Listener bekommen automatisch Updates
/// wenn neue Eintraege hinzukommen oder das Collection-Flag toggled wird.
class ScanHistoryNotifier
    extends AsyncNotifier<List<ScanHistoryEntry>> {
  @override
  Future<List<ScanHistoryEntry>> build() async {
    final store = ref.read(scanHistoryStoreProvider);
    return store.load();
  }

  /// Fuegt einen neuen Verlaufseintrag hinzu. Wenn `dedupeAgainstTopOfList`
  /// gesetzt ist und der oberste Eintrag bereits dieselbe cardId hat, wird
  /// nichts hinzugefuegt (verhindert dass der Scan-Stream 20x dieselbe
  /// Karte hintereinander schreibt).
  Future<void> addEntry(
    ScanHistoryEntry entry, {
    bool dedupeAgainstTopOfList = true,
  }) async {
    // WICHTIG: zuerst auf build() warten, sonst ueberschreibt der Disk-
    // Load (der noch lief) unseren frisch gesetzten state.
    await future;
    final current = state.valueOrNull ?? const <ScanHistoryEntry>[];
    if (dedupeAgainstTopOfList &&
        current.isNotEmpty &&
        current.first.cardId == entry.cardId) {
      return;
    }
    final next = [entry, ...current];
    state = AsyncValue.data(next);
    await ref.read(scanHistoryStoreProvider).save(next);
  }

  Future<void> toggleCollection(String entryId) async {
    await future;
    final current = state.valueOrNull ?? const <ScanHistoryEntry>[];
    final next = [
      for (final e in current)
        if (e.id == entryId)
          e.copyWith(inCollection: !e.inCollection)
        else
          e,
    ];
    state = AsyncValue.data(next);
    await ref.read(scanHistoryStoreProvider).save(next);
  }

  Future<void> remove(String entryId) async {
    await future;
    final current = state.valueOrNull ?? const <ScanHistoryEntry>[];
    final next = [for (final e in current) if (e.id != entryId) e];
    state = AsyncValue.data(next);
    await ref.read(scanHistoryStoreProvider).save(next);
  }

  /// Ersetzt fuer den Verlaufseintrag `entryId` Karten-Identitaet und
  /// Metadaten durch die uebergebenen Werte (Korrektur-Workflow).
  /// `inCollection`, `scannedAt` und `similarity` werden uebernommen,
  /// damit der Eintrag an seiner Position im Verlauf bleibt.
  Future<void> replaceCard({
    required String entryId,
    required String cardId,
    required String cardName,
    required String setCode,
    required String number,
    required String language,
    String? rarity,
    String? imageUrl,
    int? cardmarketMetacardId,
    int? cardmarketProductId,
    int? cardmarketExpansionId,
  }) async {
    await future;
    final current = state.valueOrNull ?? const <ScanHistoryEntry>[];
    final next = [
      for (final e in current)
        if (e.id == entryId)
          ScanHistoryEntry(
            id: e.id,
            cardId: cardId,
            cardName: cardName,
            setCode: setCode,
            number: number,
            language: language,
            rarity: rarity,
            imageUrl: imageUrl,
            scannedAt: e.scannedAt,
            similarity: e.similarity,
            inCollection: e.inCollection,
            cardmarketMetacardId: cardmarketMetacardId,
            cardmarketProductId: cardmarketProductId,
            cardmarketExpansionId: cardmarketExpansionId,
          )
        else
          e,
    ];
    state = AsyncValue.data(next);
    await ref.read(scanHistoryStoreProvider).save(next);
  }

  Future<void> clearAll() async {
    await future;
    state = const AsyncValue.data([]);
    await ref.read(scanHistoryStoreProvider).save(const []);
  }

  /// Setzt fuer alle Verlaufseintraege mit dieser `cardId` das
  /// `inCollection`-Flag auf [value]. Wenn `value=true` und es noch
  /// keinen Eintrag fuer diese Karte gibt, wird ein manueller Eintrag
  /// mit `similarity=1.0` angelegt (Hinzufuegen direkt vom Detail-Screen).
  /// Liefert true wenn die Karte danach in der Sammlung ist.
  Future<bool> setInCollectionForCard({
    required String cardId,
    required bool value,
    required String cardName,
    required String setCode,
    required String number,
    required String language,
    String? rarity,
    String? imageUrl,
    int? cardmarketMetacardId,
    int? cardmarketProductId,
    int? cardmarketExpansionId,
  }) async {
    await future;
    final current = state.valueOrNull ?? const <ScanHistoryEntry>[];
    final hasAny = current.any((e) => e.cardId == cardId);

    if (!hasAny) {
      if (!value) return false; // nichts zu tun
      final entry = ScanHistoryEntry(
        id: '${DateTime.now().millisecondsSinceEpoch}-$cardId-manual',
        cardId: cardId,
        cardName: cardName,
        setCode: setCode,
        number: number,
        language: language,
        rarity: rarity,
        imageUrl: imageUrl,
        scannedAt: DateTime.now(),
        similarity: 1.0,
        inCollection: true,
        cardmarketMetacardId: cardmarketMetacardId,
        cardmarketProductId: cardmarketProductId,
        cardmarketExpansionId: cardmarketExpansionId,
      );
      final next = [entry, ...current];
      state = AsyncValue.data(next);
      await ref.read(scanHistoryStoreProvider).save(next);
      return true;
    }

    final next = [
      for (final e in current)
        if (e.cardId == cardId) e.copyWith(inCollection: value) else e,
    ];
    state = AsyncValue.data(next);
    await ref.read(scanHistoryStoreProvider).save(next);
    return value;
  }
}

final scanHistoryProvider =
    AsyncNotifierProvider<ScanHistoryNotifier, List<ScanHistoryEntry>>(
  ScanHistoryNotifier.new,
);

/// Erzeugt einen CSV-Text aus einer Liste von Eintraegen. Spalten:
/// scanned_at, card_name, set_code, number, language, rarity, similarity,
/// in_collection, card_id, cardmarket_metacard_id, cardmarket_product_id,
/// image_url. CSV ist RFC4180-konform: Felder werden in Quotes geschrieben
/// wenn sie Komma/Quote/Newline enthalten.
String exportEntriesToCsv(List<ScanHistoryEntry> entries) {
  final buf = StringBuffer();
  buf.writeln(
    'scanned_at,card_name,set_code,number,language,rarity,similarity,'
    'in_collection,card_id,cardmarket_metacard_id,cardmarket_product_id,'
    'image_url',
  );
  for (final e in entries) {
    buf.writeln([
      _csv(e.scannedAt.toIso8601String()),
      _csv(e.cardName),
      _csv(e.setCode),
      _csv(e.number),
      _csv(e.language),
      _csv(e.rarity ?? ''),
      _csv(e.similarity.toStringAsFixed(4)),
      _csv(e.inCollection ? 'true' : 'false'),
      _csv(e.cardId),
      _csv(e.cardmarketMetacardId?.toString() ?? ''),
      _csv(e.cardmarketProductId?.toString() ?? ''),
      _csv(e.imageUrl ?? ''),
    ].join(','));
  }
  return buf.toString();
}

String _csv(String value) {
  if (value.contains(',') || value.contains('"') || value.contains('\n')) {
    final escaped = value.replaceAll('"', '""');
    return '"$escaped"';
  }
  return value;
}

/// Schreibt CSV ins temp-Verzeichnis und gibt den File-Pfad zurueck,
/// damit der Caller per share_plus weiter teilen kann.
Future<File> writeCsvToTemp(String csv, {String? filenamePrefix}) async {
  final dir = await getTemporaryDirectory();
  final stamp = DateTime.now()
      .toIso8601String()
      .replaceAll(':', '-')
      .replaceAll('.', '-');
  final name = '${filenamePrefix ?? 'opa-macht-auge'}-$stamp.csv';
  final f = File(p.join(dir.path, name));
  await f.writeAsString(csv, flush: true);
  return f;
}
