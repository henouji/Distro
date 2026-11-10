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
  test('old light configurations get three empty preset slots', () {
    final json = config.toJson()..remove('presets');
    expect(LightConfig.fromJson(json).presets, [null, null, null]);
  });
  test('presets round trip and survive device edits and restarts', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(lightsProvider.notifier);
    await controller.save(config);
    for (var slot = 0; slot < 3; slot++) {
      await controller.savePreset(
        config.id,
        slot,
        LightPreset(
          name: 'Preset $slot',
          brightness: 25.0 * slot,
          temperature: 30,
          hue: slot == 2 ? 200 : null,
          saturation: .6,
        ),
      );
    }
    final saved = (await container.read(lightsProvider.future)).single;
    await controller.save(
      LightConfig.fromJson({...saved.toJson(), 'name': 'Renamed'}),
    );
    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    final light = (await restored.read(lightsProvider.future)).single;
    expect(light.name, 'Renamed');
    expect(light.presets, hasLength(3));
    expect(light.presets[2]!.hue, 200);
    expect(light.presets[2]!.saturation, .6);
    expect(light.presets[2]!.brightness, 50);
    expect(light.presets[0]!.temperature, 30);
    expect(
      () => const LightPreset(name: '', brightness: 50).validate(),
      throwsA(isA<HomeHubException>()),
    );
    await expectLater(
      controller.savePreset(
        config.id,
        3,
        const LightPreset(name: 'Invalid slot', brightness: 50),
      ),
      throwsRangeError,
    );
  });
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
  test(
    'detect protocol with status only, independently of configured DP mapping',
    () async {
      final attempts = <double>[];
      final transports = <FakeTransport>[];
      final provider = TuyaLanLightProvider(
        createTransport: (candidate) {
          attempts.add(candidate.version);
          final transport = FakeTransport()
            ..response = candidate.version == 3.5
                ? {
                    'dps': {'1': true, '3': 50},
                  }
                : {'Error': 'response timeout'};
          transports.add(transport);
          return transport;
        },
      );
      final result = await provider.detectProtocol(config);
      expect(attempts, [3.3, 3.5]);
      expect(result.version, 3.5);
      expect(result.dataPoints, [1, 3]);
      expect(
        transports.every(
          (transport) => transport.closed && transport.writes.isEmpty,
        ),
        isTrue,
      );
    },
  );
  test(
    'protocol detection rejects ACK-only replies and sanitizes failures',
    () async {
      final attempts = <double>[];
      final provider = TuyaLanLightProvider(
        createTransport: (candidate) {
          attempts.add(candidate.version);
          return FakeTransport()..response = {'success': true};
        },
      );
      await expectLater(
        provider.detectProtocol(config),
        throwsA(
          isA<HomeHubException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('No supported protocol'),
              isNot(contains(config.localKey)),
            ),
          ),
        ),
      );
      expect(attempts, [3.3, 3.5, 3.4, 3.1]);
    },
  );
  test('brightness selects white mode and scales to v2 range', () async {
    final transport = FakeTransport();
    final provider = TuyaLanLightProvider(createTransport: (_) => transport);
    await provider.setBrightness(config, 50);
    expect(transport.writes, {21: 'white', 22: 505});
  });
  test(
    'scheduled white uses one connection and individual DP writes',
    () async {
      final transport = FakeTransport();
      var connections = 0;
      final provider = TuyaLanLightProvider(
        createTransport: (_) {
          connections++;
          return transport;
        },
      );
      await provider.setScheduledWhite(config, 50, 25);
      expect(connections, 1);
      expect(transport.writes, {21: 'white', 23: 250, 22: 505, 20: true});
      expect(transport.closed, isTrue);
    },
  );
  test('notification toggles power based on fresh bulb status', () async {
    final transport = FakeTransport();
    final info = await TuyaLanLightProvider(
      createTransport: (_) => transport,
    ).quickControl(config, 'toggle');
    expect(transport.writes, {20: false});
    expect(info['on'], isFalse);
    expect(info['name'], config.name);
    expect(transport.closed, isTrue);
  });
  test('notification adjusts white brightness and temperature', () async {
    for (final (action, expected) in [
      ('dim', {21: 'white', 22: 406, 20: true}),
      ('brighten', {21: 'white', 22: 604, 20: true}),
      ('warm', {21: 'white', 23: 0, 20: true}),
      ('cool', {21: 'white', 23: 1000, 20: true}),
    ]) {
      final transport = FakeTransport();
      await TuyaLanLightProvider(
        createTransport: (_) => transport,
      ).quickControl(config, action);
      expect(transport.writes, expected);
    }
  });
  test(
    'notification colors preserve brightness and dim without changing hue',
    () async {
      final rgb = LightConfig.fromJson({...config.toJson(), 'colorDp': 24});
      final transport = FakeTransport()
        ..response = {
          'dps': {
            '20': true,
            '21': 'colour',
            '22': 505,
            '23': 500,
            '24': '00d203e801f4',
          },
        };
      final provider = TuyaLanLightProvider(createTransport: (_) => transport);
      final dimmed = await provider.quickControl(rgb, 'dim');
      expect(transport.writes, {24: '00d203e80190', 20: true});
      expect(dimmed['brightness'], 40);
      expect(dimmed['hasColor'], isTrue);
      transport.writes.clear();
      final red = await provider.quickControl(rgb, 'red');
      expect(transport.writes, {21: 'colour', 24: '000003e801f4', 20: true});
      expect(red['brightness'], 50);
    },
  );
  test('compact notification cycles colors from current bulb state', () async {
    final rgb = LightConfig.fromJson({...config.toJson(), 'colorDp': 24});
    final transport = FakeTransport();
    final provider = TuyaLanLightProvider(createTransport: (_) => transport);
    transport.response = {
      'dps': {
        '20': true,
        '21': 'white',
        '22': 505,
        '23': 500,
        '24': '000003e801f4',
      },
    };
    for (final expectedColor in [
      '000003e801f4', // Red from white.
      '002d03e801f4',
      '008203e801f4',
      '00d203e801f4',
      '000003e801f4',
    ]) {
      transport.writes.clear();
      final info = await provider.quickControl(rgb, 'color');
      expect(transport.writes, {21: 'colour', 24: expectedColor, 20: true});
      expect(info['brightness'], 50);
      transport.response = {
        'dps': {
          '20': true,
          '21': 'colour',
          '22': 505,
          '23': 500,
          '24': expectedColor,
        },
      };
    }
  });
  test(
    'compact white alternates warm and cool and leaves color mode',
    () async {
      final rgb = LightConfig.fromJson({...config.toJson(), 'colorDp': 24});
      for (final (mode, temperature, expected) in [
        ('white', 500, 0),
        ('white', 0, 1000),
        ('white', 1000, 0),
        ('colour', 0, 0),
      ]) {
        final transport = FakeTransport()
          ..response = {
            'dps': {
              '20': true,
              '21': mode,
              '22': 505,
              '23': temperature,
              '24': '00d203e801f4',
            },
          };
        await TuyaLanLightProvider(
          createTransport: (_) => transport,
        ).quickControl(rgb, 'white');
        expect(transport.writes, {21: 'white', 23: expected, 20: true});
      }
    },
  );
  test(
    'notification rejects unsupported controls and invalid color without writing',
    () async {
      final transport = FakeTransport();
      final provider = TuyaLanLightProvider(createTransport: (_) => transport);
      for (final action in ['red', 'color', 'invalid']) {
        await expectLater(
          provider.quickControl(config, action),
          throwsA(isA<HomeHubException>()),
        );
        expect(transport.writes, isEmpty);
      }
      final rgb = LightConfig.fromJson({...config.toJson(), 'colorDp': 24});
      for (final value in ['invalid', 'ffff03e803e8']) {
        transport.response = {
          'dps': {'20': true, '21': 'colour', '24': value},
        };
        await expectLater(
          provider.quickControl(rgb, 'dim'),
          throwsA(isA<HomeHubException>()),
        );
        expect(transport.writes, isEmpty);
      }
    },
  );
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
  test('classify LAN failures without exposing raw errors or credentials', () {
    final cases = <String, String>{
      'Unable to connect to device after 1 attempts':
          'Cannot open the local connection',
      'TimeoutException: response timeout': 'The bulb did not reply in time',
      'Session key negotiation failed': 'Tuya session handshake failed',
      'Invalid padding during decrypt': 'Cannot decode the bulb response',
      'FormatException: invalid JSON': 'Cannot decode the bulb response',
      'unexpected private response': 'The cause is not yet identified',
    };
    for (final entry in cases.entries) {
      try {
        TuyaLanLightProvider.checkResponse({
          'Error': '${entry.key}: ${config.localKey}',
        });
        fail('Expected a sanitized LAN error');
      } on HomeHubException catch (error) {
        expect(error.message, contains(entry.value));
        expect(error.message, isNot(contains(config.localKey)));
        expect(error.message, isNot(contains('unexpected private response')));
      }
    }
  });
  test('classify numeric LAN error codes', () {
    for (final entry in {
      901: 'Cannot open the local connection',
      905: 'Cannot open the local connection',
      902: 'The bulb did not reply in time',
      914: 'Cannot decode the bulb response',
    }.entries) {
      expect(
        () => TuyaLanLightProvider.checkResponse({'Err': '${entry.key}'}),
        throwsA(
          isA<HomeHubException>().having(
            (error) => error.message,
            'message',
            contains(entry.value),
          ),
        ),
      );
    }
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
