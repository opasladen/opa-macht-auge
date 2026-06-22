# app - Opa macht Auge (Flutter)

Mobile-Client (Android/iOS). Erkennt Pokemon-Karten via Kamera, identifiziert
sie on-device per Embedding, fragt Live-Marktpreise vom Backend ab.

## Erste Inbetriebnahme

```powershell
# Plattform-Ordner (android/, ios/) erstmalig anlegen:
flutter create .

flutter pub get

# Code-Generierung (Riverpod, Freezed, Drift):
dart run build_runner build --delete-conflicting-outputs

flutter run
```

## Struktur

```
lib/
  core/               Theme, Router, DI-Konstanten, Logger
  features/
    scan/             Kamera-Stream, Detector-Inference, Crop-Pipeline
    identify/         Embedding-Lookup, OCR (MLKit)
    catalog/          Eigene Sammlung (Drift)
    market/           Preis-Anzeige + Trend
  data/
    local/            Drift-Schema + DAOs
    remote/           Dio-Clients (manuell + generated/)
    models/           Freezed/Json DTOs
assets/
  models/             *.tflite (YOLOv8n + Embedder), per CI in Releases gepackt
```

## State-Management

Riverpod 2 mit Code-Generierung. Provider liegen neben ihrem Feature.
`go_router` haengt am rootProvider via `routerProvider`.

## Offline-Strategie

- Karten-Metadaten (Bulk) als komprimierte SQLite in `assets/` mitgeliefert
- Scans im Drift-`scans`-Table mit `synced=false` markiert, periodischer Sync
