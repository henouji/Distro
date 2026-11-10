import 'dart:convert';

import '../../core/local_network.dart';

enum DpProfile { modern, legacy, custom }

class LightConfig {
  const LightConfig({
    required this.id,
    required this.name,
    required this.host,
    required this.localKey,
    this.version = 3.3,
    this.profile = DpProfile.modern,
    this.switchDp = 20,
    this.modeDp = 21,
    this.brightnessDp = 22,
    this.temperatureDp = 23,
    this.colorDp,
    this.brightnessMin = 10,
    this.valueMax = 1000,
  });

  final String id, name, host, localKey;
  final double version;
  final DpProfile profile;
  final int switchDp, brightnessMin, valueMax;
  final int? modeDp, brightnessDp, temperatureDp, colorDp;

  void validate() {
    requireLocalAddress(host);
    if (id.trim().isEmpty || name.trim().isEmpty) {
      throw const HomeHubException('Enter a device ID and name.');
    }
    if (utf8.encode(localKey).length != 16) {
      throw const HomeHubException(
        'A Tuya local key must contain exactly 16 UTF-8 bytes.',
      );
    }
    if (![3.1, 3.3, 3.4, 3.5].contains(version)) {
      throw const HomeHubException('Choose a supported Tuya protocol version.');
    }
    final points = [
      switchDp,
      modeDp,
      brightnessDp,
      temperatureDp,
      colorDp,
    ].whereType<int>().toList();
    if (points.any((point) => point < 1 || point > 255) ||
        points.toSet().length != points.length ||
        brightnessMin < 0 ||
        valueMax <= brightnessMin) {
      throw const HomeHubException(
        'Check data-point IDs and brightness range.',
      );
    }
    if (colorDp != null && modeDp == null) {
      throw const HomeHubException(
        'Color control also requires a mode data point.',
      );
    }
  }

  int brightnessValue(double percent) =>
      (brightnessMin + (valueMax - brightnessMin) * percent.clamp(0, 100) / 100)
          .round();

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'localKey': localKey,
    'version': version,
    'profile': profile.name,
    'switchDp': switchDp,
    'modeDp': modeDp,
    'brightnessDp': brightnessDp,
    'temperatureDp': temperatureDp,
    'colorDp': colorDp,
    'brightnessMin': brightnessMin,
    'valueMax': valueMax,
  };

  factory LightConfig.fromJson(Map<String, dynamic> json) => LightConfig(
    id: json['id'] as String,
    name: json['name'] as String,
    host: json['host'] as String,
    localKey: json['localKey'] as String,
    version: (json['version'] as num).toDouble(),
    profile: DpProfile.values.byName(json['profile'] as String),
    switchDp: json['switchDp'] as int,
    modeDp: json['modeDp'] as int?,
    brightnessDp: json['brightnessDp'] as int?,
    temperatureDp: json['temperatureDp'] as int?,
    colorDp: json['colorDp'] as int?,
    brightnessMin: json['brightnessMin'] as int,
    valueMax: json['valueMax'] as int,
  );
}

class LightState {
  const LightState({
    required this.config,
    this.online = false,
    this.on = false,
    this.brightness = 100,
    this.temperature = 50,
    this.error,
    this.hasBrightness = false,
    this.hasTemperature = false,
    this.hasColor = false,
  });

  final LightConfig config;
  final bool online, on, hasBrightness, hasTemperature, hasColor;
  final double brightness, temperature;
  final String? error;

  factory LightState.fromDps(LightConfig config, Map<String, dynamic> dps) {
    if (dps['${config.switchDp}'] is! bool) {
      throw const HomeHubException(
        'The switch data point was not found. Check the DP mapping.',
      );
    }
    final brightness = dps['${config.brightnessDp}'];
    final temperature = dps['${config.temperatureDp}'];
    return LightState(
      config: config,
      online: true,
      on: dps['${config.switchDp}'] as bool,
      hasBrightness: brightness is num,
      hasTemperature: temperature is num,
      hasColor: config.colorDp != null && dps.containsKey('${config.colorDp}'),
      brightness: brightness is num
          ? ((brightness - config.brightnessMin) *
                    100 /
                    (config.valueMax - config.brightnessMin))
                .clamp(0, 100)
                .toDouble()
          : 100,
      temperature: temperature is num
          ? (temperature * 100 / config.valueMax).clamp(0, 100).toDouble()
          : 50,
    );
  }
}
