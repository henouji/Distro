import 'dart:convert';
import 'dart:typed_data';

import '../tv_platform.dart';
import '../tv_sync_controller.dart';
import '../tv_sync_engine.dart';

const tvRemotePort = 47870;

class RemoteLight {
  const RemoteLight({required this.id, required this.name, this.mode});
  final String id, name;
  final SyncMode? mode;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'mode': mode?.name};

  factory RemoteLight.fromJson(Map<String, dynamic> json) => RemoteLight(
    id: json['id'] as String,
    name: json['name'] as String,
    mode: SyncMode.values.where((mode) => mode.name == json['mode']).firstOrNull,
  );
}

/// Everything the tablet needs to draw its TV screen, sent by the TV.
class TvRemoteSnapshot {
  const TvRemoteSnapshot({
    required this.name,
    required this.status,
    required this.settings,
    required this.lights,
    required this.app,
    this.lightId,
    this.mode,
    this.error,
    this.preview,
  });

  final String name;
  final TvSyncStatus status;
  final SyncSettings settings;
  final List<RemoteLight> lights;
  final ForegroundApp app;
  final String? lightId, error;
  final SyncMode? mode;

  /// Color currently shown by the synced light.
  final (int, int, int)? preview;

  factory TvRemoteSnapshot.fromSync(
    String name,
    TvSyncState sync,
    List<RemoteLight> lights,
    ForegroundApp app,
  ) => TvRemoteSnapshot(
    name: name,
    status: sync.status,
    settings: sync.settings,
    lights: lights,
    app: app,
    lightId: sync.lightId,
    mode: sync.mode,
    error: sync.error,
    preview: sync.preview == null
        ? null
        : sync.mode == SyncMode.color
        ? sync.preview!.rgb
        : whitePreview(sync.preview!),
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'status': status.name,
    'lightId': lightId,
    'mode': mode?.name,
    'error': error,
    'preview': preview == null ? null : [preview!.$1, preview!.$2, preview!.$3],
    'settings': {
      'minBrightness': settings.minBrightness,
      'maxBrightness': settings.maxBrightness,
      'smoothing': settings.smoothing,
    },
    'lights': [for (final light in lights) light.toJson()],
    'app': {
      'usageAccess': app.usageAccess,
      'package': app.package,
      'label': app.label,
    },
  };

  factory TvRemoteSnapshot.fromJson(Map<String, dynamic> json) {
    final settings = Map<String, dynamic>.from(json['settings'] as Map);
    final app = Map<String, dynamic>.from(json['app'] as Map);
    final preview = (json['preview'] as List?)?.cast<num>();
    return TvRemoteSnapshot(
      name: json['name'] as String,
      status: TvSyncStatus.values.byName(json['status'] as String),
      lightId: json['lightId'] as String?,
      mode: SyncMode.values
          .where((mode) => mode.name == json['mode'])
          .firstOrNull,
      error: json['error'] as String?,
      preview: preview == null || preview.length != 3
          ? null
          : (preview[0].toInt(), preview[1].toInt(), preview[2].toInt()),
      settings: SyncSettings(
        minBrightness: (settings['minBrightness'] as num).toDouble(),
        maxBrightness: (settings['maxBrightness'] as num).toDouble(),
        smoothing: (settings['smoothing'] as num).toDouble(),
      ),
      lights: [
        for (final light in json['lights'] as List)
          RemoteLight.fromJson(Map<String, dynamic>.from(light as Map)),
      ],
      app: ForegroundApp(
        usageAccess: app['usageAccess'] == true,
        package: app['package'] as String?,
        label: app['label'] as String?,
      ),
    );
  }
}

/// Approximates a tunable-white light frame as an on-screen color.
(int, int, int) whitePreview(LightFrame frame) {
  final level = (frame.brightness.clamp(0, 100) / 100).clamp(.08, 1);
  final cool = frame.temperature.clamp(0, 100) / 100;
  int channel(int warm, int coolValue) =>
      ((warm + (coolValue - warm) * cool) * level).round();
  return (channel(255, 227), channel(194, 238), channel(122, 255));
}

Map<String, dynamic> tvAppToJson(TvApp app) => {
  'package': app.package,
  'label': app.label,
  'icon': app.icon == null ? null : base64Encode(app.icon!),
};

TvApp tvAppFromJson(Map<String, dynamic> json) => TvApp(
  package: json['package'] as String,
  label: json['label'] as String,
  icon: json['icon'] == null
      ? null
      : Uint8List.fromList(base64Decode(json['icon'] as String)),
);
