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
      final code = int.tryParse('${response['Err']}');
      final description = '${response['Error'] ?? ''}'.toLowerCase();
      if (code == 901 ||
          code == 905 ||
          description.contains('unable to connect') ||
          description.contains('connection refused') ||
          description.contains('network is unreachable')) {
        throw const HomeHubException(
          'Cannot open the local connection. Check the bulb IP and home Wi-Fi, '
          'and force-stop Smart Life before retrying.',
        );
      }
      if (code == 902 ||
          description.contains('timeout') ||
          description.contains('timed out')) {
        throw const HomeHubException(
          'The bulb did not reply in time. Close other Tuya clients and verify '
          'the protocol version advertised by the bulb.',
        );
      }
      if (description.contains('session key negotiation')) {
        throw const HomeHubException(
          'Tuya session handshake failed. Verify the bulb protocol version and '
          'that the current local key belongs to this device ID.',
        );
      }
      if (code == 914 ||
          code == 900 ||
          description.contains('decrypt') ||
          description.contains('padding') ||
          description.contains('authentication') ||
          description.contains('json')) {
        throw const HomeHubException(
          'Cannot decode the bulb response. Verify its protocol version and '
          'local key before changing DP mappings.',
        );
      }
      throw const HomeHubException(
        'The Tuya LAN request failed. The cause is not yet identified. '
        'Verify the protocol version and current local key; this does not '
        'confirm a DP mapping problem.',
      );
    }
  }

  @override
  Future<LightState> read(LightConfig config) =>
      _run(config, (transport) async {
        return LightState.fromDps(config, await _readDps(transport));
      });

  Future<Map<String, dynamic>> _readDps(LanTransport transport) async {
    final response = await transport.status();
    checkResponse(response);
    final data =
        response['dps'] ??
        (response['data'] is Map ? response['data']['dps'] : null);
    if (data is! Map || data.isEmpty) {
      throw const HomeHubException(
        'The light returned no status. Check its protocol version and local key.',
      );
    }
    return Map<String, dynamic>.from(data);
  }

  Future<({double version, List<int> dataPoints})> detectProtocol(
    LightConfig config, {
    void Function(double version)? onAttempt,
  }) async {
    config.validate();
    for (final version in {config.version, 3.5, 3.4, 3.3, 3.1}) {
      onAttempt?.call(version);
      final candidate = LightConfig.fromJson({
        ...config.toJson(),
        'version': version,
      });
      try {
        final points = await _run(candidate, _readDps);
        return (
          version: version,
          dataPoints: points.keys.map(int.tryParse).whereType<int>().toList()
            ..sort(),
        );
      } on HomeHubException {
        continue;
      }
    }
    throw const HomeHubException(
      'No supported protocol returned valid status. Check that the current '
      'local key, device ID and IP belong to the same bulb. Close Tuya clients '
      'on other phones. No light commands were sent.',
    );
  }

  Future<void> _write(LightConfig config, Map<int, Object> values) =>
      _run(config, (transport) async {
        for (final entry in values.entries) {
          checkResponse(await transport.write(entry.key, entry.value));
        }
      });

  Future<void> setScheduledWhite(
    LightConfig config,
    double brightness,
    double temperature,
  ) {
    if (config.brightnessDp == null || config.temperatureDp == null) {
      throw const HomeHubException(
        'Scheduled lighting requires brightness and temperature data points.',
      );
    }
    return _write(config, {
      if (config.modeDp != null) config.modeDp!: 'white',
      config.temperatureDp!: (temperature * config.valueMax / 100).round(),
      config.brightnessDp!: config.brightnessValue(brightness),
      config.switchDp: true,
    });
  }

  Future<Map<String, Object>> quickControl(
    LightConfig config,
    String requestedAction,
  ) => _run(config, (transport) async {
    var dps = await _readDps(transport);
    final light = LightState.fromDps(config, dps);
    final format = config.profile == DpProfile.legacy ? 'rgb8' : 'hsv16';
    List<double>? color;
    if (dps['${config.modeDp}'] == 'colour') {
      final encoded = dps['${config.colorDp}'];
      if (encoded is! String ||
          !RegExp(r'^[0-9a-fA-F]+$').hasMatch(encoded) ||
          !(format == 'rgb8' ? [6, 14] : [12]).contains(encoded.length)) {
        throw const HomeHubException(
          'The bulb returned an invalid color value.',
        );
      }
      color = tuya.BulbDevice.hexvalueToHsv(encoded, hexformat: format);
      if (color.any((value) => !value.isFinite || value < 0 || value > 1)) {
        throw const HomeHubException(
          'The bulb returned an invalid color range.',
        );
      }
    }
    final values = <int, Object>{};
    final brightness = color == null ? light.brightness / 100 : color[2];
    final action = switch (requestedAction) {
      'white' => color != null || light.temperature >= 50 ? 'warm' : 'cool',
      'color' =>
        color == null
            ? 'red'
            : switch (color[0] * 360) {
                < 44 => 'amber',
                < 129 => 'green',
                < 209 => 'blue',
                _ => 'red',
              },
      _ => requestedAction,
    };
    switch (action) {
      case 'refresh':
        break;
      case 'toggle':
        values[config.switchDp] = !light.on;
      case 'dim':
      case 'brighten':
        final next = (brightness + (action == 'dim' ? -.1 : .1)).clamp(
          .01,
          1.0,
        );
        if (color != null && light.hasColor) {
          values[config.colorDp!] = tuya.BulbDevice.hsvToHexvalue(
            color[0],
            color[1],
            next,
            format,
          );
        } else if (light.hasBrightness) {
          if (config.modeDp != null) values[config.modeDp!] = 'white';
          values[config.brightnessDp!] = config.brightnessValue(next * 100);
        } else {
          throw const HomeHubException(
            'Brightness is not supported by this light.',
          );
        }
        values[config.switchDp] = true;
      case 'warm':
      case 'cool':
        if (!light.hasTemperature) {
          throw const HomeHubException(
            'White temperature is not supported by this light.',
          );
        }
        if (config.modeDp != null) values[config.modeDp!] = 'white';
        values[config.temperatureDp!] = action == 'warm' ? 0 : config.valueMax;
        values[config.switchDp] = true;
      case 'red':
      case 'amber':
      case 'green':
      case 'blue':
        if (!light.hasColor || config.modeDp == null) {
          throw const HomeHubException('Color is not supported by this light.');
        }
        final hue = switch (action) {
          'red' => 0.0,
          'amber' => 45.0,
          'green' => 130.0,
          _ => 210.0,
        };
        values[config.modeDp!] = 'colour';
        values[config.colorDp!] = tuya.BulbDevice.hsvToHexvalue(
          hue / 360,
          1,
          brightness.clamp(.01, 1),
          format,
        );
        values[config.switchDp] = true;
      default:
        throw const HomeHubException('Unknown notification light control.');
    }
    for (final entry in values.entries) {
      checkResponse(await transport.write(entry.key, entry.value));
    }
    dps = {
      ...dps,
      for (final entry in values.entries) '${entry.key}': entry.value,
    };
    final current = LightState.fromDps(config, dps);
    final inColor = dps['${config.modeDp}'] == 'colour';
    final currentBrightness = inColor
        ? tuya.BulbDevice.hexvalueToHsv(
                dps['${config.colorDp}'] as String,
                hexformat: format,
              )[2] *
              100
        : current.brightness;
    return {
      'name': config.name,
      'on': current.on,
      'brightness': currentBrightness.round(),
      'hasBrightness': current.hasBrightness || current.hasColor,
      'hasTemperature': current.hasTemperature,
      'hasColor': current.hasColor,
    };
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
