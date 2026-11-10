import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homehub/core/local_network.dart';
import 'package:homehub/core/storage.dart';
import 'package:homehub/features/lights/components/light_schedule_editor.dart';
import 'package:homehub/features/lights/components/lighting_schedule_screen.dart';
import 'package:homehub/features/lights/light.dart';
import 'package:homehub/features/lights/light_schedule.dart';
import 'package:homehub/features/lights/lighting_runtime.dart';
import 'package:homehub/features/lights/lights_controller.dart';
import 'package:homehub/features/tv_sync/tv_sync_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

const timeline = LightSchedule(
  days: [1, 3, 5],
  points: [
    LightingPoint(minute: 420, brightness: 20, temperature: 10),
    LightingPoint(minute: 540, brightness: 100, temperature: 90),
    LightingPoint(minute: 1260, brightness: 10, temperature: 0),
  ],
);
const scheduledLight = LightConfig(
  id: 'scheduled-light',
  name: 'Scheduled lamp',
  host: '192.168.1.20',
  localKey: '0123456789abcdef',
  schedule: timeline,
);

class FakeLightingRuntime extends LightingRuntime {
  bool running = false;
  String? lightId;
  String? error;

  @override
  Future<void> start() async => running = true;
  @override
  Future<void> stop() async => running = false;
  @override
  Future<void> pin(String id) async => lightId = id;
  @override
  Future<void> hide() async => lightId = null;
  @override
  Future<Map<String, dynamic>> status() async => {
    'running': running,
    'error': error,
    'quickLightId': lightId,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('timeline interpolates exact endpoints and intermediate values', () {
    // 9 November 2026 is Monday.
    final start = timeline.at(DateTime(2026, 11, 9, 7))!;
    expect(start.brightness, 20);
    expect(start.temperature, 10);
    final midpoint = timeline.at(DateTime(2026, 11, 9, 8))!;
    expect(midpoint.brightness, 60);
    expect(midpoint.temperature, 50);
    final boundary = timeline.at(DateTime(2026, 11, 9, 9))!;
    expect(boundary.brightness, 100);
    expect(boundary.temperature, 90);
    final evening = timeline.at(DateTime(2026, 11, 9, 15))!;
    expect(evening.brightness, 55);
    expect(evening.temperature, 45);
    final seconds = timeline.at(DateTime(2026, 11, 9, 7, 0, 30))!;
    expect(seconds.brightness, closeTo(20 + 80 / 240, .000001));
  });

  test('timeline respects weekdays, local midnight and disabled state', () {
    expect(timeline.at(DateTime(2026, 11, 9, 6, 59, 59)), isNull);
    expect(timeline.at(DateTime(2026, 11, 9, 21))!.brightness, 10);
    expect(timeline.at(DateTime(2026, 11, 9, 23, 59))!.temperature, 0);
    expect(timeline.at(DateTime(2026, 11, 10)), isNull);
    expect(timeline.at(DateTime(2026, 11, 10, 8)), isNull);
    expect(timeline.at(DateTime(2026, 11, 11, 8))!.brightness, 60);
    final disabled = LightSchedule.fromJson({
      ...timeline.toJson(),
      'enabled': false,
    });
    expect(disabled.at(DateTime(2026, 11, 9, 8)), isNull);
  });

  test(
    'reject invalid days, duplicate times, bounds and non-finite values',
    () {
      for (final json in [
        {...timeline.toJson(), 'days': []},
        {
          ...timeline.toJson(),
          'days': [0],
        },
        {
          ...timeline.toJson(),
          'days': [8],
        },
        {
          ...timeline.toJson(),
          'days': [1, 1],
        },
        {
          ...timeline.toJson(),
          'points': [timeline.points.first.toJson()],
        },
        {
          ...timeline.toJson(),
          'points': [
            timeline.points.first.toJson(),
            timeline.points.first.toJson(),
          ],
        },
        {
          ...timeline.toJson(),
          'points': timeline.points.reversed.map((p) => p.toJson()).toList(),
        },
        for (final value in [-1, 1440])
          {
            ...timeline.toJson(),
            'points': [
              {...timeline.points.first.toJson(), 'minute': value},
              timeline.points.last.toJson(),
            ],
          },
        for (final field in ['brightness', 'temperature'])
          for (final value in [-1, 101, double.nan, double.infinity])
            {
              ...timeline.toJson(),
              'points': [
                {...timeline.points.first.toJson(), field: value},
                timeline.points.last.toJson(),
              ],
            },
      ]) {
        expect(
          () => LightSchedule.fromJson(json),
          throwsA(isA<HomeHubException>()),
        );
      }
    },
  );

  test(
    'schedule persists across edits and restarts; old configs stay unscheduled',
    () async {
      final old = scheduledLight.toJson()..remove('schedule');
      expect(LightConfig.fromJson(old).schedule, isNull);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(lightsProvider.notifier);
      await controller.save(scheduledLight);
      await controller.savePreset(
        scheduledLight.id,
        0,
        const LightPreset(name: 'Evening', brightness: 20),
      );
      final saved = (await container.read(lightsProvider.future)).single;
      await controller.save(
        LightConfig.fromJson({
          ...saved.toJson(),
          'id': 'new-id',
          'name': 'Renamed',
        }),
        previousId: saved.id,
      );
      final restored = ProviderContainer();
      addTearDown(restored.dispose);
      final light = (await restored.read(lightsProvider.future)).single;
      expect(light.schedule!.toJson(), timeline.toJson());
      expect(light.id, 'new-id');
      expect(light.presets.first!.name, 'Evening');
      expect(
        () => LightConfig.fromJson({
          ...light.toJson(),
          'temperatureDp': null,
        }).validate(),
        throwsA(isA<HomeHubException>()),
      );
      await controller.delete(light.id);
      expect(await container.read(lightsProvider.future), isEmpty);
    },
  );

  test(
    'runner reloads configuration, isolates failures and recovers',
    () async {
      var lights = [scheduledLight];
      final sent = <(String, double, double)>[];
      var fail = true;
      final runner = LightingRunner(
        load: () async => lights,
        send: (light, point) async {
          if (light.id == scheduledLight.id && fail) {
            throw const HomeHubException('Light timed out.');
          }
          sent.add((light.id, point.brightness, point.temperature));
        },
      );
      lights = [
        scheduledLight,
        LightConfig.fromJson({...scheduledLight.toJson(), 'id': 'other'}),
      ];
      expect(
        await runner.tick(DateTime(2026, 11, 9, 8)),
        contains('Scheduled lamp: Light timed out.'),
      );
      expect(sent.single, ('other', 60, 50));
      fail = false;
      expect(await runner.tick(DateTime(2026, 11, 9, 9)), isNull);
      expect(sent.last, ('other', 100, 90));
      lights = [];
      final count = sent.length;
      await runner.tick(DateTime(2026, 11, 9, 10));
      expect(sent.length, count);
      lights = [scheduledLight];
      await runner.tick(DateTime(2026, 11, 10, 10));
      expect(sent.length, count);
    },
  );

  test('runner never overlaps LAN update batches', () async {
    final gate = Completer<void>();
    var writes = 0;
    final runner = LightingRunner(
      load: () async => [scheduledLight],
      send: (_, point) async {
        writes++;
        await gate.future;
      },
    );
    final first = runner.tick(DateTime(2026, 11, 9, 8));
    await Future<void>.delayed(Duration.zero);
    await runner.tick(DateTime(2026, 11, 9, 9));
    expect(writes, 1);
    gate.complete();
    await first;
  });

  test(
    'TV Sync rejects enabled schedules before connecting to the light',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await const CredentialVault().writeList('lights', [
        scheduledLight.toJson(),
      ]);
      final container = ProviderContainer(
        overrides: [preferencesProvider.overrideWithValue(preferences)],
      );
      addTearDown(container.dispose);
      final sync = container.read(tvSyncProvider.notifier);
      await sync.selectLight(scheduledLight.id);
      await sync.start();
      expect(container.read(tvSyncProvider).status, TvSyncStatus.idle);
      expect(container.read(tvSyncProvider).error, contains('Disable'));
    },
  );

  for (final width in [375.0, 1280.0]) {
    testWidgets('timeline editor saves weekdays and fits width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      LightSchedule? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<LightSchedule>(
                    context: context,
                    builder: (_) =>
                        const LightScheduleEditor(initial: timeline),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tue'));
      await tester.tap(find.text('Save schedule'));
      await tester.pumpAndSettle();
      expect(result!.days, [1, 2, 3, 5]);
      expect(result!.points, hasLength(3));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('runtime controls start, show failures and stop schedules', (
    tester,
  ) async {
    await const CredentialVault().writeList('lights', [
      scheduledLight.toJson(),
    ]);
    final runtime = FakeLightingRuntime();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [lightingRuntimeProvider.overrideWithValue(runtime)],
        child: const MaterialApp(home: LightingScheduleScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Schedules are stopped'), findsOneWidget);
    await tester.tap(find.text('Start schedules'));
    await tester.pumpAndSettle();
    expect(runtime.running, isTrue);
    expect(find.text('Schedules are running'), findsOneWidget);
    runtime.error = 'Scheduled lamp: Light timed out.';
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text(runtime.error!), findsOneWidget);
    await tester.tap(find.text('Stop schedules'));
    await tester.pumpAndSettle();
    expect(runtime.running, isFalse);
    expect(find.text('Schedules are stopped'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('notification controls select, pin and hide a bulb', (
    tester,
  ) async {
    await const CredentialVault().writeList('lights', [
      scheduledLight.toJson(),
    ]);
    final runtime = FakeLightingRuntime();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [lightingRuntimeProvider.overrideWithValue(runtime)],
        child: const MaterialApp(home: LightingScheduleScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(scheduledLight.name).last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Show notification controls'));
    await tester.tap(find.text('Show notification controls'));
    await tester.pumpAndSettle();
    expect(runtime.lightId, scheduledLight.id);
    await tester.tap(find.text('Hide notification controls'));
    await tester.pumpAndSettle();
    expect(runtime.lightId, isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
