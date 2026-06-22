// Drift-Skeleton vorlaeufig deaktiviert.
//
// Hintergrund: build_runner 2.4.13 + drift_dev 2.21 ziehen analyzer_plugin
// 0.12 mit, das zu analyzer 7.6 inkompatibel ist (Build-Script-Kompilierung
// schlaegt fehl). Drift wird aktuell von keiner Feature-Schicht genutzt
// (catalog_screen ist Placeholder, scan_controller schreibt direkt gegen das
// Backend). Reaktivieren sobald wir den lokalen Karten-Cache angehen:
//   1. pubspec.yaml: drift/drift_dev/build_runner auf neueste Versions hochziehen
//   2. Diesen Stub durch die Tabellen-Definitionen ersetzen (siehe Git-History)
//   3. flutter pub run build_runner build --delete-conflicting-outputs
