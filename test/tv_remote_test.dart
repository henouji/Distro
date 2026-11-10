import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:homehub/core/app.dart';
import 'package:homehub/core/local_network.dart';
import 'package:homehub/core/storage.dart';
import 'package:homehub/features/lights/light.dart';
import 'package:homehub/features/lights/lights_controller.dart';
import 'package:homehub/features/tv_sync/remote/tv_remote_client.dart';
import 'package:homehub/features/tv_sync/remote/tv_remote_host.dart';
import 'package:homehub/features/tv_sync/remote/tv_remote_protocol.dart';
import 'package:homehub/features/tv_sync/tv_platform.dart';
import 'package:homehub/features/tv_sync/tv_sync_controller.dart';
import 'package:homehub/features/tv_sync/tv_sync_engine.dart';

import 'tv_sync_test.dart'
    show FakeCapture, FakeLights, FakeStream, colorLight, whiteLight;

class FakePlatform implements TvPlatform {
  FakePlatform({this.tv = true});
  final bool tv;
  final launched = <String>[];

  @override
  Future<bool> isTv() async => tv;
  @override
  Future<List<TvApp>> listApps() async => [
    TvApp(
      package: 'com.google.android.youtube.tv',
      label: 'YouTube',
      icon: Uint8List.fromList([1, 2, 3]),
    ),
    const TvApp(package: 'com.netflix.ninja', label: 'Netflix'),
  ];
  @override
  Future<ForegroundApp> currentApp() async => const ForegroundApp(
    usageAccess: true,
    package: 'com.google.android.youtube.tv',
    label: 'YouTube',
  );
  @override
  Future<void> launchApp(String package) async => launched.add(package);
  @override
  Future<void> moveToBack() async {}
}

class FakeApi implements TvRemoteApi {
  FakeApi(this.snapshot);
  TvRemoteSnapshot snapshot;
  final calls = <String>[];

  @override
  Future<TvRemoteSnapshot> state() async => snapshot;
  @override
  Future<List<TvApp>> apps() async => [
    const TvApp(package: 'com.netflix.ninja', label: 'Netflix'),
  ];
  @override
  Future<TvRemoteSnapshot> launch(String package) async {
    calls.add('launch $package');
    return snapshot;
  }

  @override
  Future<TvRemoteSnapshot> startSync({String? lightId}) async {
    calls.add('start $lightId');
    return snapshot;
  }

  @override
  Future<TvRemoteSnapshot> stopSync() async {
    calls.add('stop');
    return snapshot;
  }

  @override
  Future<TvRemoteSnapshot> selectLight(String lightId) async => snapshot;
  @override
  Future<TvRemoteSnapshot> updateSettings(SyncSettings settings) async =>
      snapshot;
  @override
  Future<TvRemoteSnapshot> sendLights(List<LightConfig> lights) async =>
      snapshot;
}

TvRemoteSnapshot snapshot({TvSyncStatus status = TvSyncStatus.idle}) =>
    TvRemoteSnapshot(
      name: 'TV',
      status: status,
      settings: const SyncSettings(),
      lights: const [
        RemoteLight(id: 'rgb-bulb', name: 'Strip', mode: SyncMode.color),
      ],
      app: const ForegroundApp(usageAccess: true, label: 'YouTube'),
      lightId: 'rgb-bulb',
      mode: SyncMode.color,
      preview: (255, 0, 0),
    );

void main() {
  test('snapshot survives a JSON round trip', () {
    final restored = TvRemoteSnapshot.fromJson(
      snapshot(status: TvSyncStatus.running).toJson(),
    );
    expect(restored.status, TvSyncStatus.running);
    expect(restored.lightId, 'rgb-bulb');
    expect(restored.lights.single.mode, SyncMode.color);
    expect(restored.app.label, 'YouTube');
    expect(restored.preview, (255, 0, 0));
    expect(restored.settings.smoothing, const SyncSettings().smoothing);
  });

  group('TV host and tablet client', () {
    late ProviderContainer tv;
    late FakePlatform platform;
    late FakeStream stream;
    late TvRemoteHostState host;

    setUp(() async {
      // The widget-test binding fakes every HttpClient; this group needs
      // real loopback sockets.
      final overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = overrides);
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      platform = FakePlatform();
      stream = FakeStream();
      tv = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          tvRemoteHostPortProvider.overrideWithValue(0),
          tvPlatformProvider.overrideWithValue(platform),
          screenCaptureProvider.overrideWithValue(FakeCapture()),
          lightStreamFactoryProvider.overrideWithValue((_) => stream),
          lightServiceProvider.overrideWithValue(FakeLights()),
        ],
      );
      addTearDown(tv.dispose);
      await tv.read(tvRemoteHostProvider.notifier).setEnabled(true);
      host = tv.read(tvRemoteHostProvider);
    });

    Future<TvRemoteClient> pair() async => TvRemoteClient(
      await TvRemoteClient.pair(
        '127.0.0.1',
        host.pairingCode!,
        port: host.port!,
      ),
    );

    test('pairs with the code and controls the TV', () async {
      expect(host.running, isTrue);
      final client = await pair();
      expect(tv.read(tvRemoteHostProvider).paired, 1);
      expect(tv.read(tvRemoteHostProvider).pairingCode, isNot(host.pairingCode));

      var state = await client.state();
      expect(state.app.label, 'YouTube');
      expect(state.lights, isEmpty);

      state = await client.sendLights([whiteLight, colorLight]);
      expect(state.lights.map((light) => light.mode), [
        SyncMode.white,
        SyncMode.color,
      ]);
      expect(await tv.read(lightsProvider.future), hasLength(2));

      final apps = await client.apps();
      expect(apps.first.label, 'YouTube');
      expect(apps.first.icon, [1, 2, 3]);
      await client.launch('com.netflix.ninja');
      expect(platform.launched, ['com.netflix.ninja']);

      state = await client.updateSettings(
        const SyncSettings(minBrightness: 10, maxBrightness: 80, smoothing: .5),
      );
      expect(state.settings.maxBrightness, 80);

      state = await client.startSync(lightId: colorLight.id);
      expect(state.status, TvSyncStatus.running);
      expect(state.mode, SyncMode.color);
      state = await client.stopSync();
      expect(state.status, TvSyncStatus.idle);
      expect(stream.closed, isTrue);
    });

    test('rejects a wrong code and unpaired tablets', () async {
      final wrong = host.pairingCode == '000000' ? '111111' : '000000';
      await expectLater(
        TvRemoteClient.pair('127.0.0.1', wrong, port: host.port!),
        throwsA(isA<HomeHubException>()),
      );
      final stranger = TvRemoteClient(
        PairedTv(host: '127.0.0.1', port: host.port!, token: 'nope'),
      );
      await expectLater(
        stranger.state(),
        throwsA(
          isA<HomeHubException>().having(
            (error) => error.message,
            'message',
            contains('no longer paired'),
          ),
        ),
      );
    });

    test('forgetting tablets revokes their access', () async {
      final client = await pair();
      await tv.read(tvRemoteHostProvider.notifier).forgetTablets();
      await expectLater(client.state(), throwsA(isA<HomeHubException>()));
    });
  });

  testWidgets('tablet pairs and toggles Light Sync on the TV', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = FakeApi(snapshot());
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          tvPlatformProvider.overrideWithValue(FakePlatform(tv: false)),
          tvPairingProvider.overrideWithValue(
            (host, code) async => PairedTv(host: host, token: 'token'),
          ),
          tvRemoteApiFactoryProvider.overrideWithValue((_) => api),
        ],
        child: const HomeHubApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.tv_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Pair with your TV'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), '192.168.68.111');
    await tester.enterText(find.byType(TextField).at(1), '123456');
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    expect(find.text('Now on TV'), findsOneWidget);
    expect(find.text('YouTube'), findsOneWidget);
    expect(find.text('Netflix'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(api.calls, ['start rgb-bulb']);

    await tester.tap(find.text('Netflix'));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'launch com.netflix.ninja');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
