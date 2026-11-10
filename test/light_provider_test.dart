import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:homehub/core/local_network.dart';
import 'package:homehub/core/storage.dart';
import 'package:homehub/features/lights/light.dart';
import 'package:homehub/features/lights/light_provider.dart';
import 'package:homehub/features/lights/lights_controller.dart';

const config = LightConfig(
  id: 'test-device',
  name: 'Test light',
  host: '192.168.1.20',
  localKey: '0123456789abcdef',
);

class FakeTransport implements LanTransport {
  Map<String, dynamic> response = {
    'dps': {'20': true, '22': 505, '23': 500},
  };
  final writes = <int, Object>{};
  bool closed = false;
  @override
  Future<Map<String, dynamic>> status() async => response;
  @override
  Future<Map<String, dynamic>> write(int point, Object value) async {
    writes[point] = value;
    return {};
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test('only private IPv4 device destinations are accepted', () {
    for (final host in [
      '192.168.0.2',
      '10.0.0.8',
      '172.16.0.1',
      '172.31.1.2',
    ]) {
      expect(isPrivateIpv4(host), isTrue);
    }
    for (final host in [
      '8.8.8.8',
      'example.com',
      '127.0.0.1',
      '172.32.0.1',
      '169.254.1.2',
      '::1',
      '192.168.1.1.evil.com',
    ]) {
      expect(isPrivateIpv4(host), isFalse);
    }
  });
  test('read status and close the connection', () async {
    final transport = FakeTransport();
    final provider = TuyaLanLightProvider(createTransport: (_) => transport);
    final state = await provider.read(config);
    expect(state.online, isTrue);
    expect(state.on, isTrue);
    expect(state.brightness, 50);
    expect(state.temperature, 50);
    expect(state.hasColor, isFalse);
    expect(transport.closed, isTrue);
  });
  test('brightness selects white mode and scales to v2 range', () async {
    final transport = FakeTransport();
    final provider = TuyaLanLightProvider(createTransport: (_) => transport);
    await provider.setBrightness(config, 50);
    expect(transport.writes, {21: 'white', 22: 505});
  });
  test('legacy mapping uses legacy brightness range', () async {
    const legacy = LightConfig(
      id: 'test',
      name: 'Legacy',
      host: '10.0.0.2',
      localKey: '0123456789abcdef',
      profile: DpProfile.legacy,
      switchDp: 1,
      modeDp: 2,
      brightnessDp: 3,
      temperatureDp: 4,
      brightnessMin: 25,
      valueMax: 255,
    );
    final transport = FakeTransport();
    await TuyaLanLightProvider(
      createTransport: (_) => transport,
    ).setBrightness(legacy, 100);
    expect(transport.writes, {2: 'white', 3: 255});
  });
  test('reject errors without exposing response or credentials', () async {
    final transport = FakeTransport()..response = {'Error': 'secret'};
    await expectLater(
      TuyaLanLightProvider(createTransport: (_) => transport).read(config),
      throwsA(isA<HomeHubException>()),
    );
    expect(transport.closed, isTrue);
  });
  test('invalid destination never creates a transport', () async {
    var created = false;
    final provider = TuyaLanLightProvider(
      createTransport: (_) {
        created = true;
        return FakeTransport();
      },
    );
    await expectLater(
      provider.read(
        const LightConfig(
          id: 'test',
          name: 'Bad',
          host: '8.8.8.8',
          localKey: '0123456789abcdef',
        ),
      ),
      throwsA(isA<HomeHubException>()),
    );
    expect(created, isFalse);
  });
  test('credential configuration round-trips', () {
    expect(LightConfig.fromJson(config.toJson()).toJson(), config.toJson());
  });
  test(
    'light add, edit device ID and delete persist in secure storage',
    () async {
      final container = ProviderContainer.test();
      await container.read(lightsProvider.future);
      final controller = container.read(lightsProvider.notifier);
      await controller.save(config);
      final edited = LightConfig.fromJson({...config.toJson(), 'id': 'new-id'});
      await controller.save(edited, previousId: config.id);
      final stored = await container.read(vaultProvider).readList('lights');
      expect(stored.single['id'], 'new-id');
      expect(stored.single['localKey'], config.localKey);
      await controller.delete('new-id');
      expect(await container.read(vaultProvider).readList('lights'), isEmpty);
    },
  );
  test('color command uses HSV16 for modern RGB devices', () async {
    final rgb = LightConfig.fromJson({...config.toJson(), 'colorDp': 24});
    final transport = FakeTransport();
    await TuyaLanLightProvider(
      createTransport: (_) => transport,
    ).setColor(rgb, 255, 0, 0);
    expect(transport.writes, {21: 'colour', 24: '000003e803e8'});
  });
}
