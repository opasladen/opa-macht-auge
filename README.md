# Opa macht Auge

Plattformuebergreifende Mobile-App zur Erkennung, Katalogisierung und
Echtzeit-Wertbestimmung von Pokemon-Sammelkarten.

> **Stand: 2026-06-21.** Live-Scan auf echtem Handy (Pixel 8 Pro) funktioniert
> mit OCR-First-Pipeline; Sandile aus Silver Tempest wird in ca. 500 ms
> deterministisch identifiziert. Embedding-Fallback ist deaktiviert.
> Offene Themen siehe Abschnitt **Continuation Guide** unten.

## Monorepo-Struktur

```
opa-macht-auge/
  app/        Flutter Client (Dart, Riverpod 2, Drift, Dio, ML Kit, ONNX)
  backend/    FastAPI + Postgres 16 (pgvector) + Redis
  ml/         Python Training-Pipeline (YOLOv8, DINOv2-distilled Embedder, DVC)
  shared/     OpenAPI 3.1 Schema, Protobuf, gemeinsame Vertraege
  infra/      Docker, Compose, spaeter k8s / Terraform
```

## Stack-Entscheidungen (fixiert)

- Spiel-Scope V1: Pokemon TCG (Multi-Game faehig via `games.slug`)
- Backend: FastAPI, SQLAlchemy 2, Alembic, pgvector (HNSW), Redis 7
- Mobile: Flutter 3.44+, Riverpod 2, Drift, Dio, Freezed, go_router
- On-Device-OCR: `google_mlkit_text_recognition` (Latin)
- Visueller Fallback (deaktiviert): DINOv2-small ONNX, 384-D L2-norm
- ML-Training: Python 3.12, Ultralytics YOLOv8n (Detector), destilliertes DINOv2
- DevOps: Docker Compose lokal, GitHub Actions, OpenAPI als Single Source of Truth

## Workspace-Pfad

```
G:\Projekte Programmieren\Opa macht Auge
```

WSL-Datenstores und Caches liegen ebenfalls auf G:\, weil C:\ voll war.
NIEMALS Werkzeuge starten ohne folgende Env-Vars in der aktiven PowerShell:

```powershell
$env:TMP='G:\temp'
$env:TEMP='G:\temp'
$env:PUB_CACHE='G:\pub-cache'
$env:GRADLE_USER_HOME='G:\gradle'
$env:JAVA_HOME='G:\jdk17'
$env:ANDROID_HOME='G:\AndroidSdk'
$env:ANDROID_SDK_ROOT='G:\AndroidSdk'
$env:PATH="G:\jdk17\bin;G:\AndroidSdk\platform-tools;$env:PATH"
```

Flutter SDK liegt unter `G:\flutter-stable\bin\flutter.bat`.

## Schnellstart (Neusystem)

```powershell
# 1. .env anlegen
Copy-Item .env.example .env

# 2. Infrastruktur starten (Postgres + Redis)
docker compose up -d

# 3. Backend
cd backend
uv sync
uv run alembic upgrade head
uv run uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload

# 4. Datenbestand initial laden (Pokemon TCG, alle EN+DE Sets)
cd ../ml
$env:PYTHONPATH="..\backend"
uv run python -m ml.bootstrap.pokemontcg --set-code base1   # einzelner Set zum Test
# bzw. alle Sets fuer EN und DE durchziehen (kann ~30 min dauern)

# 5. printed_total fuer existierende Sets nachtragen
uv run python -m ml.bootstrap.refresh_printed_total

# 6. Flutter (in separatem Terminal mit obigen Env-Vars)
cd ../app
& "G:\flutter-stable\bin\flutter.bat" pub get
```

---

## Architektur des Scan-Flows (aktueller Stand)

```
[Pixel Kamera]
   |  takePicture (1080p JPEG, ~150-250 ms)
   v
[App-Cache /data/data/.../cache/CAP*.jpg]
   |
   v
[ML Kit TextRecognizer (Latin), on-device, ~120-200 ms]
   |  full text
   v
[OcrService._parse  -  4 Regex-Passes]
   |  (\d{1,3})/(\d{1,3})        -> number + printed_total
   |  \b\d+\s*HP\b                -> language=en
   |  \b\d+\s*KP\b                -> language=de
   |  \b([A-Z]{3})[·•⋅・](EN|DE)  -> 3-Letter-Set-Code (modern)
   v
CardCode(number, printedTotal?, language?, setCode?)
   |  isUseful? (number + mindestens ein weiteres Feld)
   v  ja                                       v nein
[POST /api/v1/identify-by-code]      [naechster Tick]
   |
   v
[Backend filtert cards JOIN card_sets, Number-zfill-Toleranz]
   |  matches (sim=1.0 wenn unique, sonst 1/n)
   v
[ScanScreen]
   |  sim >= 0.99 -> Auto-Stop, Bottom-Sheet mit Karten-Bild
   |  sonst       -> live-Status, weiter scannen
   v
[Loop Timer alle 600 ms]
```

Latenzbudget pro Tick (Best Case): ~500 ms ab Auslosen bis Treffer-Sheet
geoeffnet. Loop tickt alle 600 ms, also faktisch live.

---

## Was funktioniert (verifiziert)

- Postgres 16 + pgvector im Container `opa-postgres`, healthy
- Redis 7 im Container `opa-redis`, healthy
- Backend uvicorn auf `0.0.0.0:8000`
- Bootstrap pokemontcg.io: **39 696 / 39 932** Karten haben Embedding (99.4 %)
- `card_sets` hat 511 Sets (EN + DE), `printed_total` fuer 229 davon befuellt
- Endpoint `POST /api/v1/identify` (Embedding-Suche via pgvector HNSW)
- Endpoint `POST /api/v1/identify-by-code` (deterministischer Lookup)
- Flutter-App startet, Live-Scan-Loop funktioniert
- ML Kit OCR liest `number/total` und `HP`/`KP` zuverlaessig auf Sandile EN
- E2E Pixel 8 Pro: Sandile (swsh12 #111/195 EN) -> sim=1.000 in <1 s

Verifizierte Endpoint-Calls (PowerShell):

```powershell
# Sandile EN (eindeutig)
Invoke-RestMethod -Uri http://192.168.178.25:8000/api/v1/identify-by-code `
  -Method Post -ContentType 'application/json' `
  -Body '{"number":"111","printed_total":195,"language":"en"}'
# -> { matches: [Sandile sim=1.0], model_version: "ocr-lookup-v1" }

# Ganovil DE (eindeutig)
Invoke-RestMethod -Uri http://192.168.178.25:8000/api/v1/identify-by-code `
  -Method Post -ContentType 'application/json' `
  -Body '{"number":"111","printed_total":195,"language":"de"}'
```

---

## Was wir heute geaendert haben

### Backend

1. **Migration `add_printed_total_to_card_sets`**
   (`backend/alembic/versions/6854c91e7389_add_printed_total_to_card_sets.py`)
   - Neue Spalte `card_sets.printed_total INTEGER NULL`
   - Hintergrund: `total_cards=245` enthaelt Secret Rares (swsh12), gedruckt
     ist aber `printed_total=195` -> Karten-Aufdruck `111/195` matched nur
     mit printed_total.

2. **Endpoint `POST /api/v1/identify-by-code`**
   (`backend/app/api/v1/identify.py`)
   - Request: `{number, language?, set_code?, printed_total?, game_slug="pokemon"}`
   - SQL: filtert `Card.number IN {raw, stripped, zfill(2), zfill(3), zfill(4)}`
     + optional language/set_code/printed_total
   - Order: release_date DESC NULLS LAST, set_code, number; LIMIT 50
   - Similarity: 1.0 wenn unique, sonst 1/len(rows)
   - Response: `IdentifyResponse(matches, model_version="ocr-lookup-v1")`

3. **Bootstrap-Erweiterung**
   (`ml/ml/bootstrap/pokemontcg.py`)
   - `_upsert_set` schreibt `printed_total=raw.get("printedTotal")` mit
     ON CONFLICT DO UPDATE.

4. **Refresh-Script**
   (`ml/ml/bootstrap/refresh_printed_total.py`)
   - Single-purpose: laeuft alle pokemontcg.io /sets durch, UPDATE
     `card_sets SET printed_total` wenn API printedTotal liefert.
   - Letzter Lauf: 229 sets aktualisiert, 51 skipped (kein printedTotal in API).

### App

5. **Dependency `google_mlkit_text_recognition: ^0.13.0`**
   (`app/pubspec.yaml`)

6. **OCR-Service**
   (`app/lib/ocr/ocr_service.dart`, NEU)
   - Klasse `CardCode(number, printedTotal, language, setCode)` mit `isUseful`-Flag
   - Klasse `OcrService.extractFromFile(path)` -> CardCode?
   - 4 Regex-Patterns siehe Architektur-Diagramm oben
   - Set-Lang-Pattern verlangt zwingend Bullet/Mittelpunkt, sonst false-positives
     auf Worte wie GENERATIONS (matched `EN` am Wortende)
   - Debug-Log `[OCR] raw="..."` mit dem rohen ML-Kit-Output
   - Riverpod-Provider `ocrServiceProvider` mit auto-dispose

7. **DTO / API**
   - `IdentifyByCodeRequest` in `app/lib/data/dto/identify_dto.dart`
   - `IdentifyApi.identifyByCode(...)` in `app/lib/data/api/identify_api.dart`

8. **Scan-Pipeline OCR-only**
   (`app/lib/features/scan/scan_controller.dart`)
   - `identifyFromFile(File)`:
     1. OCR -> CardCode
     2. wenn isUseful: POST /identify-by-code
     3. wenn nicht: state = data(null), naechster Tick
   - DINOv2-Embedding-Fallback ist **entfernt** (Tot-Code bleibt im File
     fuer spaetere Reaktivierung).

9. **Scan-Screen Performance**
   (`app/lib/features/scan/scan_screen.dart`)
   - `ResolutionPreset.ultraHigh` -> `veryHigh` (4K -> 1080p)
   - `_liveScanInterval`: 1500 ms -> 600 ms
   - `_autoStopSimilarity`: 0.80 -> 0.99

### Build-Konfiguration

- App nutzt `String.fromEnvironment('BACKEND_BASE_URL', default='http://10.0.2.2:8000')`
  in `app/lib/core/http_client.dart`
- Fuer Emulator: defaultValue funktioniert (10.0.2.2 = Host-Loopback)
- Fuer echtes Handy: Build mit `--dart-define=BACKEND_BASE_URL=http://192.168.178.25:8000`
- Cleartext-HTTP ist in `AndroidManifest.xml` via `usesCleartextTraffic="true"` erlaubt

### Netzwerk-Setup fuer Pixel-Tests

- Windows-Firewall-Regel: `New-NetFirewallRule -DisplayName "Opa macht Auge Backend 8000" -Direction Inbound -Protocol TCP -LocalPort 8000 -Action Allow -Profile Any`
- WLAN-Profil muss `Private` sein (`Set-NetConnectionProfile -InterfaceAlias 'WLAN 3' -NetworkCategory Private`)
- Pixel ueber Wireless ADB verbunden: `adb mdns services` + `adb -s adb-XXX-tcp.local.tcp connect`

---

## Befehls-Spickzettel

### Backend starten

```powershell
$env:TMP='G:\temp'; $env:TEMP='G:\temp'
cd backend
uv run uvicorn app.main:app --host 0.0.0.0 --port 8000 --log-level info
```

### App fuer Pixel bauen + deployen

```powershell
$env:TMP='G:\temp'; $env:TEMP='G:\temp'
$env:PUB_CACHE='G:\pub-cache'; $env:GRADLE_USER_HOME='G:\gradle'
$env:JAVA_HOME='G:\jdk17'; $env:ANDROID_HOME='G:\AndroidSdk'
$env:ANDROID_SDK_ROOT='G:\AndroidSdk'
$env:PATH="G:\jdk17\bin;G:\AndroidSdk\platform-tools;$env:PATH"
cd app

& "G:\flutter-stable\bin\flutter.bat" build apk --debug `
  --dart-define=BACKEND_BASE_URL=http://192.168.178.25:8000

# Pixel-Device-ID dynamisch holen
$pixel = (& adb devices -l) | Select-String 'husky' |
         ForEach-Object { ($_ -split '\s+')[0] }

& adb -s $pixel install -r "build\app\outputs\flutter-apk\app-debug.apk"
& adb -s $pixel shell am force-stop de.opaauge.opa_macht_auge
& adb -s $pixel shell am start -n de.opaauge.opa_macht_auge/.MainActivity
```

### Logcat filtern

```powershell
$pixel = (& adb devices -l | Select-String 'husky' |
          ForEach-Object { ($_ -split '\s+')[0] })
$pid_ = & adb -s $pixel shell pidof de.opaauge.opa_macht_auge
& adb -s $pixel logcat -d --pid=$pid_ |
  Select-String '\[Scan\]|\[OCR\]|flutter :|Response.*Status'
```

### Wireless ADB Pairing

```powershell
# Auf dem Handy: Entwickleroptionen -> Drahtloses Debugging
# -> "Geraet mit Kopplungscode koppeln" -> IP, Port, 6-stelliger Code merken
& adb pair 192.168.178.113:<PAIRING_PORT> <CODE>
# Connect-Port via mDNS automatisch finden:
& adb mdns services           # listet adb-XXX._adb-tls-connect._tcp
& adb connect adb-XXX._adb-tls-connect._tcp
```

### Postgres-Spickzettel

```powershell
# In Container reinschauen
docker exec -it opa-postgres psql -U opa -d opa_macht_auge

# Sets-Status auf einen Blick
docker exec opa-postgres psql -U opa -d opa_macht_auge -c `
  "SELECT language, COUNT(*), COUNT(printed_total), COUNT(symbol_asset_url)
   FROM card_sets GROUP BY language;"
```

### Docker-Engine wiederbeleben (wenn haengt)

```powershell
Get-Process | Where-Object { $_.ProcessName -match 'Docker|com\.docker|vpnkit' } |
  Stop-Process -Force
wsl --shutdown
Start-Process 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
# ~5 s warten, dann docker ps
```

---

## Continuation Guide (was als naechstes anliegt)

### Priorisiert nach Wirkung

**P1 - `printed_total` fuer SV-Sets nachziehen**
- Status: 511 Sets in DB, nur 229 haben `printed_total`. Alle modernen
  SV-Sets (sv01 Karmesin & Purpur bis sv07 Stellarkrone) sind NULL.
- Ursache vermutet: pokemontcg.io /sets liefert das Feld bei den SV-Sets
  nicht, oder das Refresh-Script verwendet falsche Set-Code-Mappings
  (`sv01` vs `sv1`).
- Aktion: `ml/ml/bootstrap/refresh_printed_total.py` debuggen, ggf.
  zweite Quelle (TCGdex REST `https://api.tcgdex.net/v2/en/sets`) als
  Fallback einbauen.
- Verifizieren: `SELECT code, printed_total FROM card_sets WHERE code LIKE 'sv%'`
  sollte fuer SV01-SV09 keine NULLs mehr enthalten.

**P2 - Tournament-Codes (SVI, PAL, OBF, MEW, PAF, TWM, SFA, SCR, ...)**
- Status: nicht in DB. Auf modernen Karten steht unten links z. B.
  `SVI · EN` (Scarlet & Violet Base). Pokemontcg.io kennt diese Codes
  nicht.
- Aktion: Neue Spalte `card_sets.printed_code VARCHAR(8)` via Alembic-Migration.
  Mapping pflegen via Hardcode-JSON (es sind ueberschaubar viele Sets):
  - `sv01 -> SVI`, `sv02 -> PAL`, `sv03 -> OBF`, `sv04 -> PAR`,
    `sv05 -> MEW`, `sv05.5 -> PAF`, `sv06 -> TWM`, `sv06.5 -> SFA`,
    `sv07 -> SCR`, `sv08 -> SSP`, `sv08.5 -> SVP`, `sv09 -> JTG`, etc.
- Backend: `/identify-by-code` filtert dann ueber `printed_code = set_code`
  wenn die App OCR den 3-Letter-Code liefert.

**P3 - Symbol-CNN als Auto-Disambiguierung**
- Status: 298 Sets haben `symbol_asset_url`, aber kein Image-Download +
  kein Klassifier.
- Aktion: Mini-CNN (ResNet18 oder MobileNetV3) trainieren auf den
  Set-Symbol-PNGs. ROI = Bottom-Left 10 % der Karte. Wenn OCR den
  Tournament-Code nicht liest, klassifiziert das Symbol das Set.

**P4 - Image-Stream statt takePicture**
- Status: `controller.takePicture()` kostet trotzdem ~200 ms Disk-Roundtrip.
- Aktion: `controller.startImageStream(...)` mit YUV-Frames, ML Kit
  `InputImage.fromBytes` direkt. Ziel: 5-10 OCR-Versuche/s ohne Foto-Aufnahme.

**P5 - Multi-Sprache-Anzeige bei `language=null`**
- Status: Wenn OCR kein HP/KP findet, kommen 2 Treffer (EN + DE), sim=0.5,
  kein Auto-Stop -> User wartet bis HP/KP doch erkannt wird.
- Aktion: Wenn matches.length<=2 und alle gleiche `(set_code, number)`
  haben, beide als waehlbares Dialog-Element zeigen.

**P6 - Image-Decoder fuer Card-Detail-Screen**
- Status: Existiert noch nicht. Bottom-Sheet ist minimal.
- Aktion: Drift-Lokal-Cache fuer eigene Sammlung, Preis-Abruf
  (Cardmarket-Adapter) zeigen.

### Bekannte Annoyances

- Flutter Release-Build mit R8 dauert > 5 min auf G:\, Debug nimmt nur 17 s.
  Debug-Build ist fuer alle Tests ausreichend (`usesCleartextTraffic`
  ist im Manifest dauerhaft an).
- `flutter.bat build` schreibt Warnings auf stderr -> PowerShell
  klassifiziert das als ExitCode 1. APK wird trotzdem korrekt gebaut.
  Pruefen via Existenz von `build/app/outputs/flutter-apk/app-debug.apk`
  und LastWriteTime.
- ML Kit erzeugt beim ersten Start auf jedem Geraet einen einmaligen
  ~85-MB-Model-Download. Pixel 8 hat das schon.
- Wireless-ADB-Pairing-Code wechselt jedes Mal beim Schliessen des
  Dialogs am Handy. mDNS-Connect ist persistent ueber Reboots.

### Test-Karten

- **Sandile** swsh12 #111/195 EN - Standard-Smoke-Test, sollte sim=1.0
  in <1 s liefern.
- **Ganovil** swsh12 #111/195 DE - identischer Smoke-Test fuer DE-Pfad.
- Beide haben `printed_total=195` in der DB.

### Stil-Konventionen

- Deutsch, sachlich-analytisch, keine Emojis.
- Antwort-Schema bei groesseren Aenderungen:
  1. Architektur-Analyse  2. Technischer Loesungsansatz
  3. Optimierungspotenzial  4. Naechster Meilenstein.
- Subagents nutzen wo sinnvoll (Explore fuer Recherche).

---

## Prinzipien

- Performance vor Framework-Bloat
- Skalierbar auf Millionen Karten + taegliche Preis-Updates
- API-first, DAL-first, Service-orientiert
- On-Device-Inferenz wo moeglich, Backend nur fuer dynamische Daten
- Deterministische Identifikation (OCR + Lookup) vor probabilistischer
  (Embedding-Similarity)
