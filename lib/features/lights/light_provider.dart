import 'dart:async';

import 'package:tinytuya/tinytuya.dart' as tuya;

import '../../core/local_network.dart';
import 'light.dart';

abstract interface class LightProvider {
  Future<LightState> read(LightConfig config);
  Future<void> setPower(LightConfig config, bool on);
  Future<void> setBrightness(LightConfig config, double percent);
  Future<void> setTemperature(LightConfig config, double percent);
  Future<void> setColor(LightConfig config, int red, int green, int blue);
}

abstract interface class LanTransport {
  Future<Map<String, dynamic>> status();
  Future<Map<String, dynamic>> write(int point, Object value);
  Future<void> close();
}

class TuyaTransport implements LanTransport {
  TuyaTransport(LightConfig config)
    : device = tuya.Device(
        deviceId: config.id,
        address: config.host,
        localKey: config.localKey,
        version: config.version,
        connectionTimeout: const Duration(seconds: 4),
        socketRetryLimit: 1,
        socketRetryDelay: Duration.zero,
      );
  final tuya.Device device;
  @override
  Future<Map<String, dynamic>> status() => device.status();
  @override
  Future<Map<String, dynamic>> write(int point, Object value) =>
      device.setValue(index: point, value: value);
  @override
  Future<void> close() async {
    await device.close();
  }
}

class TuyaLanLightProvider implements LightProvider {
  TuyaLanLightProvider({LanTransport Function(LightConfig)? createTransport})
    : _createTransport = createTransport ?? TuyaTransport.new;
  final LanTransport Function(LightConfig) _createTransport;
  final Map<String, Future<void>> _pending = {};

  Future<T> _run<T>(
    LightConfig config,
    Future<T> Function(LanTransport) action,
  ) async {
    config.validate();
    final previous = _pending[config.id];
    final gate = Completer<void>();
    _pending[config.id] = gate.future;
    if (previous != null) await previous;
    LanTransport? transport;
    try {
      transport = _createTransport(config);
      return await action(transport).timeout(const Duration(seconds: 15));
    } on HomeHubException {
      rethrow;
    } on TimeoutException {
      throw const HomeHubException(
        'Light timed out. Check power, Wi-Fi and the protocol version.',
      );
    } catch (_) {
      throw const HomeHubException(
        'Cannot reach the light. Check its IP, local key and protocol version. Close Smart Life and retry.',
      );
    } finally {
      try {
        await transport?.close();
      } finally {
        gate.complete();
        if (identical(_pending[config.id], gate.future)) {
          _pending.remove(config.id);
        }
      }
    }
  }

  static void checkResponse(Map<String, dynamic> response) {
    if (response.containsKey('Error') ||
        response.containsKey('Err') ||
        response['success'] == false) {
      throw const HomeHubException(
        'The light rejected the request. Check the local key, protocol version and DP mapping.',
      );
    }
  }

  @override
  Future<LightState> read(LightConfig config) => _run(config, (
    transport,
  ) async {
    final response = await transport.status();
    checkResponse(response);
    final data =
        response['dps'] ??
        (response['data'] is Map ? response['data']['dps'] : null);
    if (data is! Map) {
      throw const HomeHubException(
        'The light returned no status. Check its protocol version and local key.',
      );
    }
    return LightState.fromDps(config, Map<String, dynamic>.from(data));
  });

  Future<void> _write(LightConfig config, Map<int, Object> values) =>
      _run(config, (transport) async {
        for (final entry in values.entries) {
          checkResponse(await transport.write(entry.key, entry.value));
        }
      });

  @override
  Future<void> setPower(LightConfig config, bool on) =>
      _write(config, {config.switchDp: on});

  @override
  Future<void> setBrightness(LightConfig config, double percent) {
    if (config.brightnessDp == null) {
      throw const HomeHubException('Brightness is not configured.');
    }
    return _write(config, {
      if (config.modeDp != null) config.modeDp!: 'white',
      config.brightnessDp!: config.brightnessValue(percent),
    });
  }

  @override
  Future<void> setTemperature(LightConfig config, double percent) {
    if (config.temperatureDp == null) {
      throw const HomeHubException('Color temperature is not configured.');
    }
    return _write(config, {
      if (config.modeDp != null) config.modeDp!: 'white',
      config.temperatureDp!: (percent.clamp(0, 100) * config.valueMax / 100)
          .round(),
    });
  }

  @override
  Future<void> setColor(LightConfig config, int red, int green, int blue) {
    if (config.colorDp == null || config.modeDp == null) {
      throw const HomeHubException(
        'Color is not supported by this configuration.',
      );
    }
    return _write(config, {
      config.modeDp!: 'colour',
      config.colorDp!: tuya.BulbDevice.rgbToHexvalue(
        red,
        green,
        blue,
        config.profile == DpProfile.legacy ? 'rgb8' : 'hsv16',
      ),
    });
  }
}
