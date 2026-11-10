import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tinytuya/tinytuya.dart' as tuya;
import 'package:homehub/core/app.dart';
import 'package:homehub/core/local_network.dart';
import 'package:homehub/core/storage.dart';
import 'package:homehub/features/lights/light.dart';
import 'package:homehub/features/lights/light_provider.dart';
import 'package:homehub/features/lights/lights_controller.dart';
import 'package:homehub/features/tv_sync/components/tv_sync_screen/tv_sync_screen.dart';
import 'package:homehub/features/tv_sync/remote/tv_remote_host.dart';
import 'package:homehub/features/tv_sync/screen_capture.dart';
import 'package:homehub/features/tv_sync/tv_platform.dart';
import 'package:homehub/features/tv_sync/tv_sync_controller.dart';
import 'package:homehub/features/tv_sync/tv_sync_engine.dart';

const whiteLight = LightConfig(
  id: 'white-bulb',
  name: 'Lamp',
  host: '192.168.1.20',
  localKey: '0123456789abcdef',
);
const colorLight = LightConfig(
  id: 'rgb-bulb',
  name: 'Strip',
  host: '192.168.1.21',
  localKey: '0123456789abcdef',
  colorDp: 24,
);

const red = ScreenColor(red: 255, green: 0, blue: 0, luma: 1);
const black = ScreenColor(red: 0, green: 0, blue: 0, luma: 0);

class RecordingTuyaDevice extends tuya.Device {
  RecordingTuyaDevice()
    : super(
        deviceId: colorLight.id,
        address: colorLight.host,
        localKey: colorLight.localKey,
      );

  final writes = <(String, Object, bool)>[];
  bool reject = false;
  bool closed = false;

  @override
  Future<Map<String, dynamic>> setValue({
    required dynamic index,
    required dynamic value,
    bool nowait = false,
  }) async {
    writes.add((index as String, value as Object, nowait));
    return reject ? {'Error': 'Rejected', 'success': false} : {'success': true};
  }

  @override
  Future<Map<String, dynamic>> setMultipleValues(
    Map<dynamic, dynamic> dps, {
    bool nowait = false,
  }) => throw StateError('Bulk writes produce a nested dps payload.');

  @override
  Future<void> close() async => closed = true;
}

class FakeCapture implements ScreenCapture {
  FakeCapture({this.allow = true});
  final bool allow;
  final frames = StreamController<ScreenColor>.broadcast();
  bool started = false, stopped = false;

  @override
  Stream<ScreenColor> get colors => frames.stream;
  @override
  Future<bool> start({int fps = 15}) async => started = allow;
  @override
  Future<void> stop() async => stopped = true;
}

class FakeStream implements LightStream {
  final sent = <(Map<int, Object>, bool)>[];
  bool closed = false;
  @override
  Future<void> send(Map<int, Object> dps, {bool confirm = false}) async =>
      sent.add((dps, confirm));
  @override
  Future<void> close() async => closed = true;
}

class FakeLights implements LightProvider {
  final calls = <String>[];
  @override
  Future<LightState> read(LightConfig config) async => LightState(
    config: config,
    online: true,
    on: true,
    brightness: 40,
    temperature: 30,
    hasBrightness: true,
    hasTemperature: true,
  );
  @override
  Future<void> setBrightness(LightConfig config, double percent) async =>
      calls.add('brightness $percent');
  @override
  Future<void> setTemperature(LightConfig config, double percent) async =>
      calls.add('temperature $percent');
  @override
  Future<void> setPower(LightConfig config, bool on) async =>
      calls.add('power $on');
  @override
  Future<void> setColor(LightConfig config, int r, int g, int b) async =>
      calls.add('color');
}

void main() {
  test('Android capture defaults to five samples per second', () async {
    const channel = MethodChannel('homehub/screen_capture');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    expect(await AndroidScreenCapture().start(), isTrue);
    expect(calls.single.method, 'start');
    expect(calls.single.arguments, {'fps': 5});
  });

  test('Tuya sync uses individual DP writes for startup and frames', () async {
    final device = RecordingTuyaDevice();
    final stream = TuyaLightStream(colorLight, device: device);
    await stream.send(
      LightFrame.startDps(colorLight, SyncMode.color),
      confirm: true,
    );
    await stream.send({24: '000003e803e8'});
    await stream.send({22: 500, 23: 300});
    expect(device.writes, [
      ('20', true, false),
      ('21', 'colour', false),
      ('24', '000003e803e8', true),
      ('22', 500, true),
      ('23', 300, true),
    ]);
    device.reject = true;
    await expectLater(
      stream.send({22: 500}, confirm: true),
      throwsA(isA<HomeHubException>()),
    );
    await stream.close();
    expect(device.closed, isTrue);
  });

  group('SyncEngine', () {
    test('caps light updates at five per second', () {
      final engine = SyncEngine(settings: const SyncSettings(smoothing: 0));
      expect(engine.next(red, Duration.zero), isNotNull);
      expect(engine.next(black, const Duration(milliseconds: 199)), isNull);
      expect(engine.next(black, const Duration(milliseconds: 200)), isNotNull);
    });

    test('sends the first frame immediately and maps a red scene', () {
      final engine = SyncEngine();
      final frame = engine.next(red, Duration.zero)!;
      expect(frame.hue, 0);
      expect(frame.saturation, 1);
      expect(frame.brightness, 100);
      expect(frame.rgb, (255, 0, 0));
    });

    test('rate limits and skips unchanged frames until keep-alive', () {
      final engine = SyncEngine();
      engine.next(red, Duration.zero);
      expect(engine.next(black, const Duration(milliseconds: 50)), isNull);
      expect(engine.next(red, const Duration(seconds: 1)), isNull);
      expect(engine.next(red, const Duration(seconds: 9)), isNotNull);
    });

    test('breathes: brightness rises quickly and falls gradually', () {
      final engine = SyncEngine();
      engine.next(black, Duration.zero);
      final up = engine.next(
        const ScreenColor(red: 200, green: 200, blue: 200, luma: 1),
        const Duration(milliseconds: 300),
      )!;
      final down = engine.next(black, const Duration(milliseconds: 600))!;
      expect(up.brightness, greaterThan(60));
      expect(down.brightness, lessThan(up.brightness));
      expect(down.brightness, greaterThan(40));
    });

    test('dark scenes use the minimum brightness setting', () {
      final engine = SyncEngine(
        settings: const SyncSettings(minBrightness: 12, maxBrightness: 80),
      );
      expect(engine.next(black, Duration.zero)!.brightness, 12);
    });

    test('in-flight sends defer frames without dropping smoothing', () {
      final engine = SyncEngine();
      engine.next(black, Duration.zero);
      expect(
        engine.next(red, const Duration(seconds: 1), canSend: false),
        isNull,
      );
      expect(engine.next(red, const Duration(seconds: 2)), isNotNull);
    });

    test('warm scenes lower and cool scenes raise color temperature', () {
      final warm = SyncEngine().next(
        const ScreenColor(red: 255, green: 150, blue: 40, luma: .6),
        Duration.zero,
      )!;
      final cool = SyncEngine().next(
        const ScreenColor(red: 40, green: 120, blue: 255, luma: .6),
        Duration.zero,
      )!;
      expect(warm.temperature, lessThan(50));
      expect(cool.temperature, greaterThan(50));
    });
  });

  group('LightFrame.toDps', () {
    const frame = LightFrame(
      hue: 120,
      saturation: .5,
      brightness: 50,
      temperature: 25,
    );

    test('color bulbs get an hsv16 value', () {
      expect(syncModeFor(colorLight), SyncMode.color);
      expect(frame.toDps(colorLight, SyncMode.color), {24: '007801f401f4'});
      expect(LightFrame.startDps(colorLight, SyncMode.color), {
        20: true,
        21: 'colour',
      });
    });

    test('legacy color bulbs get an rgb8 value', () {
      final legacy = LightConfig.fromJson({
        ...colorLight.toJson(),
        'profile': 'legacy',
      });
      expect(frame.toDps(legacy, SyncMode.color)[24], startsWith('408040'));
    });

    test('tunable white bulbs get brightness and temperature', () {
      expect(syncModeFor(whiteLight), SyncMode.white);
      expect(frame.toDps(whiteLight, SyncMode.white), {22: 505, 23: 250});
    });
  });

  group('TvSyncController', () {
    late FakeCapture capture;
    late FakeStream stream;
    late FakeLights lights;

    Future<ProviderContainer> container({bool allow = true}) async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      capture = FakeCapture(allow: allow);
      stream = FakeStream();
      lights = FakeLights();
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          screenCaptureProvider.overrideWithValue(capture),
          lightStreamFactoryProvider.overrideWithValue((_) => stream),
          lightServiceProvider.overrideWithValue(lights),
        ],
      );
      addTearDown(container.dispose);
      await container.read(lightsProvider.notifier).save(whiteLight);
      await container.read(tvSyncProvider.notifier).selectLight(whiteLight.id);
      return container;
    }

    test(
      'streams screen colors to the light and restores it on stop',
      () async {
        final c = await container();
        final sync = c.read(tvSyncProvider.notifier);
        await sync.start();
        expect(c.read(tvSyncProvider).status, TvSyncStatus.running);
        expect(c.read(tvSyncProvider).mode, SyncMode.white);
        expect(stream.sent.first.$1, {20: true, 21: 'white'});
        expect(stream.sent.first.$2, isTrue);

        capture.frames.add(red);
        await pumpEventQueue();
        expect(stream.sent, hasLength(2));
        expect(stream.sent.last.$1.keys, [22, 23]);
        expect(stream.sent.last.$2, isFalse);
        expect(c.read(tvSyncProvider).preview, isNotNull);

        await sync.stop();
        expect(c.read(tvSyncProvider).status, TvSyncStatus.idle);
        expect(capture.stopped, isTrue);
        expect(stream.closed, isTrue);
        expect(lights.calls, ['brightness 40.0', 'temperature 30.0']);
      },
    );

    test('denied capture reports an error and releases the light', () async {
      final c = await container(allow: false);
      await c.read(tvSyncProvider.notifier).start();
      final state = c.read(tvSyncProvider);
      expect(state.status, TvSyncStatus.idle);
      expect(state.error, contains('not allowed'));
      expect(stream.closed, isTrue);
    });

    test('capture ending from the TV stops sync', () async {
      final c = await container();
      await c.read(tvSyncProvider.notifier).start();
      await capture.frames.close();
      await pumpEventQueue();
      expect(c.read(tvSyncProvider).status, TvSyncStatus.idle);
      expect(stream.closed, isTrue);
    });

    test('settings persist across restarts', () async {
      final c = await container();
      await c
          .read(tvSyncProvider.notifier)
          .updateSettings(
            const SyncSettings(
              minBrightness: 20,
              maxBrightness: 70,
              smoothing: .8,
            ),
          );
      final restored = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
        ],
      );
      addTearDown(restored.dispose);
      final state = restored.read(tvSyncProvider);
      expect(state.lightId, whiteLight.id);
      expect(state.settings.minBrightness, 20);
      expect(state.settings.maxBrightness, 70);
      expect(state.settings.smoothing, .8);
    });
  });

  testWidgets('TV Sync tab renders at TV resolution', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          deviceIsTvProvider.overrideWith((ref) async => true),
        ],
        child: const HomeHubApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.tv_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Start TV Sync'), findsOneWidget);
    expect(find.text('Add a light first in Lights.'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // D-pad Down walks past the sliders to Tablet control without changing them.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(TvSyncScreen)),
    );
    final before = container.read(tvSyncProvider).settings;
    var reachedSwitch = false;
    for (var i = 0; i < 10 && !reachedSwitch; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      reachedSwitch =
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<SwitchListTile>() !=
          null;
    }
    expect(reachedSwitch, isTrue);
    final after = container.read(tvSyncProvider).settings;
    expect(after.minBrightness, before.minBrightness);
    expect(after.maxBrightness, before.maxBrightness);
    expect(after.smoothing, before.smoothing);
  });

  for (final remoteOn in [false, true]) {
    testWidgets('D-pad reaches the bottom of TV Sync '
        '(tablet control ${remoteOn ? 'on' : 'off'})', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesProvider.overrideWithValue(
              await SharedPreferences.getInstance(),
            ),
            deviceIsTvProvider.overrideWith((ref) async => true),
            if (remoteOn) tvRemoteHostProvider.overrideWith(_RunningHost.new),
          ],
          child: const HomeHubApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.tv_outlined));
      await tester.pumpAndSettle();

      final note = find.textContaining('Protected apps');
      bool noteFocused() {
        if (note.evaluate().isEmpty) return false;
        final focused = FocusManager.instance.primaryFocus?.context;
        var found = false;
        tester.element(note).visitAncestorElements((element) {
          found = element == focused;
          return !found;
        });
        return found;
      }

      bool focusedIn<T extends Widget>() =>
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<T>() !=
          null;

      var visitedSwitch = false, visitedForget = false;
      for (var i = 0; i < 15 && !noteFocused(); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        visitedSwitch |= focusedIn<SwitchListTile>();
        visitedForget |= focusedIn<TextButton>();
      }
      expect(noteFocused(), isTrue);
      expect(visitedSwitch, isTrue);
      expect(visitedForget, remoteOn);
      if (remoteOn) expect(find.text('123456'), findsOneWidget);
      final screen = tester.getRect(find.byType(TvSyncScreen));
      expect(tester.getRect(note).bottom, lessThanOrEqualTo(screen.bottom));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(noteFocused(), isFalse);
      expect(tester.takeException(), isNull);
    });
  }
}

class _RunningHost extends TvRemoteHost {
  @override
  TvRemoteHostState build() => const TvRemoteHostState(
    enabled: true,
    running: true,
    address: '192.168.68.111',
    port: 47870,
    pairingCode: '123456',
    paired: 1,
  );
}
