import 'dart:convert';

import '../../core/local_network.dart';
import 'light_schedule.dart';

enum DpProfile { modern, legacy, custom }

class LightPreset {
  const LightPreset({
    required this.name,
    required this.brightness,
    this.temperature = 50,
    this.hue,
    this.saturation = 1,
  });

  final String name;
  final double brightness, temperature, saturation;
  final double? hue;

  void validate() {
    bool percent(double value) => value.isFinite && value >= 0 && value <= 100;
    if (name.trim().isEmpty ||
        !percent(brightness) ||
        !percent(temperature) ||
        !saturation.isFinite ||
        saturation < 0 ||
        saturation > 1 ||
        (hue != null && (!hue!.isFinite || hue! < 0 || hue! > 360))) {
      throw const HomeHubException('Check the preset name and light values.');
    }
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'brightness': brightness,
    'temperature': temperature,
    'hue': hue,
    'saturation': saturation,
  };

  factory LightPreset.fromJson(Map<String, dynamic> json) => LightPreset(
    name: json['name'] as String,
    brightness: (json['brightness'] as num).toDouble(),
    temperature: (json['temperature'] as num).toDouble(),
    hue: (json['hue'] as num?)?.toDouble(),
    saturation: (json['saturation'] as num).toDouble(),
  );
}

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
    this.presets = const [null, null, null],
    this.schedule,
  });

  final String id, name, host, localKey;
  final double version;
  final DpProfile profile;
  final int switchDp, brightnessMin, valueMax;
  final int? modeDp, brightnessDp, temperatureDp, colorDp;
  final List<LightPreset?> presets;
  final LightSchedule? schedule;

  void validate() {
    schedule?.validate();
    if (schedule != null && (brightnessDp == null || temperatureDp == null)) {
      throw const HomeHubException(
        'Scheduled lighting requires brightness and temperature data points.',
      );
    }
    if (presets.length != 3) {
      throw const HomeHubException('Each light must have three preset slots.');
    }
    for (final preset in presets.whereType<LightPreset>()) {
      preset.validate();
    }
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
    'presets': presets.map((preset) => preset?.toJson()).toList(),
    'schedule': schedule?.toJson(),
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
    schedule: json['schedule'] == null
        ? null
        : LightSchedule.fromJson(
            Map<String, dynamic>.from(json['schedule'] as Map),
          ),
    presets: json['presets'] == null
        ? const [null, null, null]
        : (json['presets'] as List)
              .map(
                (item) => item == null
                    ? null
                    : LightPreset.fromJson(
                        Map<String, dynamic>.from(item as Map),
                      ),
              )
              .toList(),
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
