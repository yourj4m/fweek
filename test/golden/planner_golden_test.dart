import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:weektodo/data/planner_store.dart';

import 'harness.dart';

void main() {
  setUpAll(loadFonts);

  testWidgets('week view, 1440x900, light', (tester) async {
    await pumpApp(tester, seededStore());
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/week_1440_light.png'));
  });

  testWidgets('week view, 1440x900, dark', (tester) async {
    await pumpApp(tester, seededStore(), brightness: Brightness.dark);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/week_1440_dark.png'));
  });

  testWidgets('week view, 390x844', (tester) async {
    await pumpApp(tester, seededStore(), size: const Size(390, 844));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/week_390_light.png'));
  });

  testWidgets('month view, 1440x900', (tester) async {
    final store = seededStore()..setSetting(Settings.view, 'month');
    await pumpApp(tester, store);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/month_1440_light.png'));
  });
}
