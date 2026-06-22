import 'package:flutter_test/flutter_test.dart';
import 'package:opa_macht_auge/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  testWidgets('App startet ohne Fehler', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: OpaMachtAugeApp()),
    );
    await tester.pump();
    expect(find.text('Karte scannen'), findsOneWidget);
  });
}
