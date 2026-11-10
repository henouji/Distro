import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:homehub/core/app.dart';
import 'package:homehub/core/storage.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('empty Home and Settings render at phone width', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [preferencesProvider.overrideWithValue(preferences)],
        child: const HomeHubApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('HomeHub'), findsOneWidget);
    expect(find.text('No lights added.'), findsOneWidget);
    expect(find.text('No cameras added.'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Appearance'), findsOneWidget);
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(preferences.getString('theme'), 'dark');
    expect(tester.takeException(), isNull);
  });

  testWidgets('camera editor validates empty fields without connecting', (
    tester,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [preferencesProvider.overrideWithValue(preferences)],
        child: const HomeHubApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.videocam_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add camera'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save Camera'));
    await tester.tap(find.text('Save Camera'));
    await tester.pumpAndSettle();
    expect(find.text('Required'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
