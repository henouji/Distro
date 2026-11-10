import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:homehub/core/app.dart';
import 'package:homehub/core/storage.dart';
import 'package:homehub/features/lights/components/light_editor.dart';
import 'package:homehub/features/lights/light.dart';
import 'package:homehub/features/lights/light_provider.dart';
import 'package:homehub/features/lights/lights_controller.dart';

class ProbeTransport implements LanTransport {
  ProbeTransport(this.version);
  final double version;

  @override
  Future<Map<String, dynamic>> status() async => version == 3.5
      ? {
          'dps': {'1': true, '3': 50},
        }
      : {'Error': 'response timeout'};

  @override
  Future<Map<String, dynamic>> write(int point, Object value) async {
    fail('Protocol detection must not send light commands.');
  }

  @override
  Future<void> close() async {}
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('detect protocol updates the editor without saving credentials', (
    tester,
  ) async {
    final service = TuyaLanLightProvider(
      createTransport: (config) => ProbeTransport(config.version),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [lightServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(
          home: LightEditor(
            config: LightConfig(
              id: 'test-device',
              name: 'Test bulb',
              host: '192.168.1.20',
              localKey: '0123456789abcdef',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Detect protocol'));
    await tester.tap(find.text('Detect protocol'));
    await tester.pumpAndSettle();
    expect(
      find.text('Status received with protocol 3.5. Available DP IDs: 1, 3'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<DropdownButtonFormField<double>>(
            find.byType(DropdownButtonFormField<double>),
          )
          .initialValue,
      3.5,
    );
    expect(await const CredentialVault().readList('lights'), isEmpty);
    expect(tester.takeException(), isNull);
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
    await tester.scrollUntilVisible(
      find.text('No cameras added.'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
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
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.byIcon(Icons.videocam_outlined),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add camera'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save Camera'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save Camera'));
    await tester.pumpAndSettle();
    expect(find.text('Required'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
