import 'dart:async';

import 'package:flutter/services.dart';
import 'package:tinytuya/tinytuya.dart' as tuya;

import '../../core/local_network.dart';
import '../lights/light.dart';
import '../lights/light_provider.dart';
import 'tv_sync_engine.dart';

/// Captures what is on this device's screen (the TV when HomeHub runs on
/// Google TV) as a stream of averaged colors.
abstract interface class ScreenCapture {
  /// Asks for capture consent and starts streaming. Returns false if denied.
  Future<bool> start({int fps});
  Future<void> stop();

  /// Emits frames while capture runs and closes when capture ends.
  Stream<ScreenColor> get colors;
}

class AndroidScreenCapture implements ScreenCapture {
  static const _methods = MethodChannel('homehub/screen_capture');
  static const _events = EventChannel('homehub/screen_capture/colors');

  @override
  Stream<ScreenColor> get colors => _events.receiveBroadcastStream().map(
    (event) => ScreenColor.fromList(List<Object?>.from(event as List)),
  );

  @override
  Future<bool> start({int fps = 5}) async {
    try {
      return await _methods.invokeMethod<bool>('start', {'fps': fps}) ?? false;
    } on MissingPluginException {
      throw const HomeHubException(
        'TV Sync needs HomeHub running on an Android or Google TV.',
      );
    } on PlatformException catch (error) {
      throw HomeHubException(
        error.message ?? 'Screen capture could not start on this device.',
      );
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _methods.invokeMethod<void>('stop');
    } on MissingPluginException {
      return;
    }
  }
}

/// A long-lived connection that pushes frequent updates to one bulb.
abstract interface class LightStream {
  /// Writes [dps]. When [confirm] is false the bulb's reply is not awaited.
  Future<void> send(Map<int, Object> dps, {bool confirm = false});
  Future<void> close();
}

class TuyaLightStream implements LightStream {
  TuyaLightStream(LightConfig config, {tuya.Device? device})
    : _device =
          device ??
          tuya.Device(
            deviceId: config.id,
            address: config.host,
            localKey: config.localKey,
            version: config.version,
            connectionTimeout: const Duration(seconds: 4),
            socketRetryLimit: 1,
            socketRetryDelay: Duration.zero,
            persist: true,
          ) {
    config.validate();
  }

  final tuya.Device _device;
  final _connected = Stopwatch();

  @override
  Future<void> send(Map<int, Object> dps, {bool confirm = false}) async {
    // Unawaited replies pile up in the client's receive buffer; reconnect
    // periodically to drop them.
    if (_connected.elapsed > const Duration(minutes: 2)) {
      await _device.close();
      _connected.reset();
    }
    _connected.start();
    // tinytuya's bulk writer nests "dps" twice; setValue encodes it correctly.
    for (final entry in dps.entries) {
      final response = await _device
          .setValue(index: '${entry.key}', value: entry.value, nowait: !confirm)
          .timeout(const Duration(seconds: 6));
      TuyaLanLightProvider.checkResponse(response);
    }
  }

  @override
  Future<void> close() async {
    _connected
      ..stop()
      ..reset();
    await _device.close();
  }
}
