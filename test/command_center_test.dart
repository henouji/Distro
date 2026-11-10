import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homehub/core/app.dart';
import 'package:homehub/core/local_network.dart';
import 'package:homehub/core/storage.dart';
import 'package:homehub/features/cameras/camera.dart';
import 'package:homehub/features/cameras/camera_ptz.dart';
import 'package:homehub/features/cameras/components/camera_controls.dart';
import 'package:homehub/features/cameras/components/camera_tile.dart';
import 'package:homehub/features/lights/components/color_wheel.dart';
import 'package:homehub/features/lights/components/light_tile.dart';
import 'package:homehub/features/lights/light.dart';
import 'package:homehub/features/lights/light_provider.dart';
import 'package:homehub/features/lights/lights_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

const commandLight = LightConfig(
  id: 'light',
  name: 'Living room',
  host: '192.168.1.20',
  localKey: '0123456789abcdef',
  colorDp: 24,
);
const commandCamera = CameraConfig(
  id: 'camera',
  name: 'Living room C200',
  host: '192.168.1.40',
  username: 'camera-user',
  password: 'test-password',
  panTilt: true,
);

class CommandLightService implements LightProvider {
  final commands = <String>[];
  bool online = true, on = true, supportsColor = true;
  double brightness = 65, temperature = 40;
  List<int>? rgb;

  @override
  Future<LightState> read(LightConfig config) async => LightState(
    config: config,
    online: online,
    on: on,
    brightness: brightness,
    temperature: temperature,
    hasBrightness: true,
    hasTemperature: true,
    hasColor: supportsColor,
  );
  @override
  Future<void> setPower(LightConfig config, bool value) async {
    commands.add('power');
    on = value;
  }

  @override
  Future<void> setBrightness(LightConfig config, double value) async {
    commands.add('brightness');
    brightness = value;
  }

  @override
  Future<void> setTemperature(LightConfig config, double value) async {
    commands.add('temperature');
    temperature = value;
  }

  @override
  Future<void> setColor(
    LightConfig config,
    int red,
    int green,
    int blue,
  ) async {
    commands.add('color');
    rgb = [red, green, blue];
  }
}

class CommandPtzController implements PtzController {
  final moves = <({double yaw, double pitch})>[];
  bool failConnect = false;
  int stops = 0;
  Completer<void>? movement;
  @override
  Future<void> connect() async {
    if (failConnect) {
      throw const HomeHubException('Camera controls unavailable.');
    }
  }

  @override
  Future<void> nudge({required double yaw, required double pitch}) async {
    moves.add((yaw: yaw, pitch: pitch));
    await movement?.future;
  }

  @override
  Future<void> stop() async => stops++;
}

Future<SharedPreferences> commandPreferences() async {
  FlutterSecureStorage.setMockInitialValues({});
  SharedPreferences.setMockInitialValues({'livePreviews': false});
  await const CredentialVault().writeList('lights', [commandLight.toJson()]);
  await const CredentialVault().writeList('cameras', [commandCamera.toJson()]);
  return SharedPreferences.getInstance();
}

void main() {
  for (final size in [
    const Size(375, 812),
    const Size(768, 1024),
    const Size(1280, 800),
    const Size(1920, 1080),
  ]) {
    testWidgets('command center adapts at ${size.width} x ${size.height}', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final preferences = await commandPreferences();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesProvider.overrideWithValue(preferences),
            lightServiceProvider.overrideWithValue(CommandLightService()),
          ],
          child: const HomeHubApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Your home, in harmony.'), findsOneWidget);
      expect(
        find.byType(NavigationRail),
        size.width >= 760 ? findsOneWidget : findsNothing,
      );
      expect(
        find.byType(NavigationBar),
        size.width < 760 ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
      final navigation = find.byType(
        size.width >= 760 ? NavigationRail : NavigationBar,
      );
      await tester.tap(
        find.descendant(
          of: navigation,
          matching: find.byIcon(Icons.lightbulb_outline),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LightTile), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(
        find.descendant(
          of: navigation,
          matching: find.byIcon(Icons.videocam_outlined),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Pan / tilt Living room C200'), findsOneWidget);
      expect(
        tester.getSize(find.byType(CameraTile)).width,
        tester.getSize(find.byType(CameraGrid)).width,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('multiple lighting cards fit a docked tablet grid', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preferences = await commandPreferences();
    await const CredentialVault().writeList('lights', [
      for (var index = 0; index < 4; index++)
        {
          ...commandLight.toJson(),
          'id': 'light-$index',
          'name': 'Living room ambient light $index',
        },
    ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          lightServiceProvider.overrideWithValue(CommandLightService()),
        ],
        child: const HomeHubApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.byIcon(Icons.lightbulb_outline),
      ),
    );
    await tester.pumpAndSettle();
    final first = tester.getRect(find.byType(LightTile).at(0));
    final second = tester.getRect(find.byType(LightTile).at(1));
    expect(first.top, second.top);
    expect(second.left - first.right, closeTo(16, .01));
    expect(first.width, greaterThan(500));
    expect(find.byType(LightTile), findsNWidgets(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('camera direction panel fits a narrow tablet sidebar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(300, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cameraPtzFactoryProvider.overrideWithValue(
            (_) => CommandPtzController(),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CameraControls(camera: commandCamera),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final tooltip in [
      'Tilt up (pitch)',
      'Pan left (yaw)',
      'Pan right (yaw)',
    ]) {
      final rect = tester.getRect(find.byTooltip(tooltip));
      expect(rect.width, greaterThanOrEqualTo(48));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(300));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'temperature and brightness send only on release; RGB presets apply',
    (tester) async {
      final service = CommandLightService();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [lightServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: LightTile(config: commandLight),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final (index, command) in [(0, 'brightness'), (1, 'temperature')]) {
        final slider = find.byType(Slider).at(index);
        final rect = tester.getRect(slider);
        final gesture = await tester.startGesture(
          Offset(rect.center.dx, rect.center.dy),
        );
        await gesture.moveTo(Offset(rect.right - 40, rect.center.dy));
        await tester.pump();
        expect(service.commands.where((item) => item == command), isEmpty);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(service.commands.where((item) => item == command), hasLength(1));
      }
      expect(service.brightness, greaterThan(80));
      expect(service.temperature, greaterThan(80));
      await tester.tap(find.text('Choose light color'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Red'));
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(service.rgb, [255, 0, 0]);
      expect(service.commands.last, 'color');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'color wheel and brightness apply together; Cancel sends nothing',
    (tester) async {
      final service = CommandLightService();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [lightServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(
            home: Scaffold(body: LightTile(config: commandLight)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose light color'));
      await tester.pumpAndSettle();
      final wheel = find.byType(ColorWheel);
      final bounds = tester.getRect(wheel);
      final gesture = await tester.startGesture(bounds.center);
      await gesture.moveTo(Offset(bounds.left + 8, bounds.center.dy));
      await gesture.up();
      await tester.pump();
      var selected = tester.widget<ColorWheel>(wheel).color;
      expect(selected.hue, closeTo(180, .01));
      expect(selected.saturation, closeTo(1, .01));
      final brightness = find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Slider),
          )
          .last;
      await tester.ensureVisible(brightness);
      await tester.tapAt(tester.getCenter(brightness));
      await tester.pump();
      selected = tester.widget<ColorWheel>(wheel).color;
      expect(selected.value, closeTo(.5, .02));
      expect(service.commands, isEmpty);
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(service.commands, ['color']);
      expect(service.rgb![0], 0);
      expect(service.rgb![1], closeTo(128, 2));
      expect(service.rgb![2], closeTo(128, 2));

      await tester.tap(find.text('Choose light color'));
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getCenter(find.byType(ColorWheel)));
      await tester.pump();
      expect(
        tester.widget<ColorWheel>(find.byType(ColorWheel)).color.saturation,
        0,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(service.commands, ['color']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'three dashboard presets can be named, saved, edited and restored',
    (tester) async {
      final preferences = await commandPreferences();
      final service = CommandLightService();
      Widget app() => ProviderScope(
        key: UniqueKey(),
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          lightServiceProvider.overrideWithValue(service),
        ],
        child: const HomeHubApp(),
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      for (var slot = 1; slot <= 3; slot++) {
        final button = find.text('Set preset $slot');
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        await tester.tap(button);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField), 'Scene $slot');
        await tester.tap(find.text('Save preset'));
        await tester.pumpAndSettle();
        expect(find.text('Scene $slot'), findsOneWidget);
      }
      expect(find.textContaining('Set preset'), findsNothing);
      expect(service.commands, isEmpty);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(LightTile)),
      );
      final saved = (await container.read(lightsProvider.future)).single;
      expect(saved.presets, hasLength(3));
      expect(saved.presets.map((preset) => preset!.name), [
        'Scene 1',
        'Scene 2',
        'Scene 3',
      ]);
      final edit = find.byTooltip('Edit preset 2');
      await tester.ensureVisible(edit);
      await tester.pumpAndSettle();
      await tester.tap(edit);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Evening');
      await tester.tap(find.text('Save preset'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.text('Evening'), findsOneWidget);
      expect(find.byTooltip('Edit preset 1'), findsOneWidget);
      expect(find.byTooltip('Edit preset 2'), findsOneWidget);
      expect(find.byTooltip('Edit preset 3'), findsOneWidget);
      final apply = find.text('Evening');
      await tester.ensureVisible(apply);
      await tester.pumpAndSettle();
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(service.commands, ['temperature', 'brightness', 'power']);
      expect(service.brightness, 100);
      expect(service.temperature, 50);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('RGB preset applies color brightness and turns on the light', (
    tester,
  ) async {
    final service = CommandLightService()..on = false;
    final config = LightConfig.fromJson({
      ...commandLight.toJson(),
      'presets': [
        const LightPreset(name: 'Dim red', brightness: 50, hue: 0).toJson(),
        null,
        null,
      ],
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [lightServiceProvider.overrideWithValue(service)],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: LightTile(config: config)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Dim red'));
    await tester.tap(find.text('Dim red'));
    await tester.pumpAndSettle();
    expect(service.commands, ['color', 'power']);
    expect(service.rgb, [128, 0, 0]);
    expect(service.on, isTrue);
    service.online = false;
    final context = tester.element(find.byType(LightTile));
    ProviderScope.containerOf(context).invalidate(lightStatusProvider(config));
    await tester.pumpAndSettle();
    final button = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('Dim red'),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets(
    'offline and switched-off lights disable sliders; unsupported RGB hidden',
    (tester) async {
      for (final online in [false, true]) {
        final service = CommandLightService()
          ..online = online
          ..on = false
          ..supportsColor = false;
        await tester.pumpWidget(
          ProviderScope(
            key: ValueKey(online),
            overrides: [lightServiceProvider.overrideWithValue(service)],
            child: const MaterialApp(
              home: Scaffold(body: LightTile(config: commandLight)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widgetList<Slider>(find.byType(Slider))
              .every((slider) => slider.onChanged == null),
          isTrue,
        );
        expect(find.text('Choose light color'), findsNothing);
        expect(
          tester.widget<Switch>(find.byType(Switch)).onChanged,
          online ? isNotNull : isNull,
        );
        expect(service.commands, isEmpty);
      }
    },
  );

  testWidgets(
    'pitch/yaw connect, issue directional commands and allow Stop while busy',
    (tester) async {
      final controller = CommandPtzController();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            cameraPtzFactoryProvider.overrideWithValue((_) => controller),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: CameraControls(camera: commandCamera),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Tilt up (pitch)'));
      expect(controller.moves, isEmpty);
      await tester.tap(find.text('Connect controls'));
      await tester.pumpAndSettle();
      for (final (label, yaw, pitch) in [
        ('Tilt up (pitch)', 0.0, 1.0),
        ('Tilt down (pitch)', 0.0, -1.0),
        ('Pan left (yaw)', -1.0, 0.0),
        ('Pan right (yaw)', 1.0, 0.0),
      ]) {
        await tester.tap(find.byTooltip(label));
        await tester.pumpAndSettle();
        expect(controller.moves.last, (yaw: yaw, pitch: pitch));
      }
      controller.movement = Completer<void>();
      await tester.tap(find.byTooltip('Pan left (yaw)'));
      await tester.pump();
      await tester.tap(find.text('Stop movement'));
      await tester.pump();
      expect(controller.stops, 1);
      controller.movement!.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed PTZ connection is visible and retryable', (tester) async {
    final controller = CommandPtzController()..failConnect = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cameraPtzFactoryProvider.overrideWithValue((_) => controller),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CameraControls(camera: commandCamera),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Connect controls'));
    await tester.pumpAndSettle();
    expect(find.text('Camera controls unavailable.'), findsOneWidget);
    controller.failConnect = false;
    await tester.tap(find.text('Connect controls'));
    await tester.pumpAndSettle();
    expect(find.text('ONVIF connected / local control'), findsOneWidget);
    expect(find.text('Camera controls unavailable.'), findsNothing);
  });
}
