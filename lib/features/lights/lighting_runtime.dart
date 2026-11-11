import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import '../../core/local_network.dart';
import '../../core/storage.dart';
import '../cameras/camera.dart';
import '../cameras/camera_events.dart';
import 'light.dart';
import 'light_provider.dart';
import 'light_schedule.dart';

class LightingRuntime {
  static const channel = MethodChannel('homehub/lighting');

  Future<void> start() => channel.invokeMethod<void>('start');
  Future<void> stop() => channel.invokeMethod<void>('stop');
  Future<void> setMotionEnabled(bool enabled) =>
      channel.invokeMethod<void>(enabled ? 'motionStart' : 'motionStop');
  Future<void> pin(String lightId) =>
      channel.invokeMethod<void>('pin', {'lightId': lightId});
  Future<void> hide() => channel.invokeMethod<void>('hide');
  Future<void> batterySettings() =>
      channel.invokeMethod<void>('batterySettings');
  Future<Map<String, dynamic>> status() async => Map<String, dynamic>.from(
    (await channel.invokeMethod<Map<Object?, Object?>>('status'))!,
  );
}

class LightingRunner {
  LightingRunner({required this.load, required this.send});

  final Future<List<LightConfig>> Function() load;
  final Future<void> Function(LightConfig, LightingPoint) send;
  bool _busy = false;

  Future<String?> tick(DateTime now) async {
    if (_busy) return null;
    _busy = true;
    try {
      final lights = await load();
      final errors = await Future.wait(
        lights.map((light) async {
          try {
            light.validate();
            final point = light.schedule?.at(now);
            if (point != null) await send(light, point);
            return null;
          } catch (error) {
            return '${light.name}: ${friendlyError(error)}';
          }
        }),
      );
      final failures = errors.whereType<String>().toList();
      return failures.isEmpty ? null : failures.join('\n');
    } finally {
      _busy = false;
    }
  }
}

class MotionLightingRunner {
  MotionLightingRunner({required this.vault, required this.provider});

  final CredentialVault vault;
  final LightProvider provider;
  final Map<String, _MotionWatcher> _watchers = {};
  final Map<String, _MotionLightState> _lightStates = {};
  final Map<String, String> _errors = {};

  String? get error =>
      _errors.values.isEmpty ? null : _errors.values.join('\n');

  Future<void> sync(bool enabled) async {
    final cameras = enabled
        ? (await vault.readList('cameras')).map(CameraConfig.fromJson).toList()
        : <CameraConfig>[];
    final lights = enabled
        ? (await vault.readList('lights')).map(LightConfig.fromJson).toList()
        : <LightConfig>[];
    final lightById = {for (final light in lights) light.id: light};
    final cameraIds = cameras.map((camera) => camera.id).toSet();
    for (final id
        in _errors.keys.where((id) => !id.startsWith('light:')).toList()) {
      if (!cameraIds.contains(id)) _errors.remove(id);
    }
    final desired = <String, ({CameraConfig camera, LightConfig light})>{};
    for (final camera in cameras) {
      final lightId = camera.motionLightId;
      if (lightId == null) {
        _errors.remove(camera.id);
        continue;
      }
      final light = lightById[lightId];
      if (light == null) {
        _errors[camera.id] =
            '${camera.name}: Choose an available light for motion automation.';
        continue;
      }
      _errors.remove(camera.id);
      desired[camera.id] = (camera: camera, light: light);
    }

    for (final entry in _watchers.entries.toList()) {
      final target = desired[entry.key];
      if (target == null ||
          entry.value.fingerprint !=
              _fingerprint(target.camera, target.light)) {
        _watchers.remove(entry.key);
        _errors.remove(entry.key);
        await entry.value.stop();
      }
    }

    final desiredLights = <String, LightConfig>{
      for (final target in desired.values) target.light.id: target.light,
    };
    for (final entry in _lightStates.entries.toList()) {
      final light = desiredLights[entry.key];
      if (light == null ||
          entry.value.fingerprint != jsonEncode(light.toJson())) {
        await entry.value.shutdown();
        _lightStates.remove(entry.key);
      }
    }
    for (final id
        in _errors.keys.where((id) => id.startsWith('light:')).toList()) {
      if (!desiredLights.containsKey(id.substring('light:'.length))) {
        _errors.remove(id);
      }
    }

    for (final entry in desired.entries) {
      if (_watchers.containsKey(entry.key)) continue;
      final target = entry.value;
      final lightState = _lightStates.putIfAbsent(
        target.light.id,
        () => _MotionLightState(
          target.light,
          provider,
          onError: (message) {
            if (message == null) {
              _errors.remove('light:${target.light.id}');
            } else {
              _errors['light:${target.light.id}'] = message;
            }
          },
        ),
      );
      _watchers[entry.key] = _MotionWatcher(
        target.camera,
        target.light,
        lightState,
        onError: (message) {
          if (message == null) {
            _errors.remove(entry.key);
          } else {
            _errors[entry.key] = message;
          }
        },
      );
    }
  }

  Future<void> stop() => sync(false);

  static String _fingerprint(CameraConfig camera, LightConfig light) =>
      jsonEncode([camera.toJson(), light.toJson()]);
}

class _MotionWatcher {
  _MotionWatcher(
    this.camera,
    LightConfig light,
    this.lightState, {
    required this.onError,
  }) : fingerprint = MotionLightingRunner._fingerprint(camera, light) {
    _task = _run();
  }

  final CameraConfig camera;
  final _MotionLightState lightState;
  final void Function(String?) onError;
  final String fingerprint;
  bool _cancelled = false;
  Future<void> _stateQueue = Future<void>.value();
  late final Future<void> _task;

  void _queueState(bool active) {
    _stateQueue = _stateQueue.then((_) async {
      try {
        await lightState.setMotionState(
          camera.id,
          active,
          brightness: camera.motionBrightness,
          hue: camera.motionHue,
          saturation: camera.motionSaturation,
          offDelay: Duration(seconds: camera.motionOffDelaySeconds),
        );
      } catch (error) {
        onError('${camera.name}: ${friendlyError(error)}');
      }
    });
  }

  Future<void> _run() async {
    while (!_cancelled) {
      try {
        await OnvifMotionProbe(camera).watchMotion(
          shouldStop: () => _cancelled,
          onState: _queueState,
          onReady: () => onError(null),
        );
        if (!_cancelled) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      } catch (error) {
        _queueState(false);
        await _stateQueue;
        if (_cancelled) break;
        onError('${camera.name}: ${friendlyError(error)}');
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    }
    _queueState(false);
    await _stateQueue;
  }

  Future<void> stop() async {
    _cancelled = true;
    await _task;
  }
}

class _MotionLightState {
  _MotionLightState(this.light, this.provider, {required this.onError})
    : fingerprint = jsonEncode(light.toJson());

  Duration _offDelay = const Duration(seconds: 20);
  final LightConfig light;
  final LightProvider provider;
  final void Function(String?) onError;
  final String fingerprint;
  final Set<String> _activeCameras = {};
  Timer? _offTimer;
  bool? _wasOn;
  double _motionBrightness = 100;
  double _motionHue = 0;
  double _motionSaturation = 1;
  Future<void> _pending = Future<void>.value();

  Future<T> _serialize<T>(Future<T> Function() action) async {
    final previous = _pending;
    final gate = Completer<void>();
    _pending = gate.future;
    await previous;
    try {
      return await action();
    } finally {
      gate.complete();
    }
  }

  Future<void> setMotionState(
    String cameraId,
    bool active, {
    required double brightness,
    required double hue,
    required double saturation,
    required Duration offDelay,
  }) => _serialize(() async {
    _offDelay = offDelay;
    if (active) {
      if (_activeCameras.contains(cameraId)) return;
      _motionBrightness = brightness;
      _motionHue = hue;
      _motionSaturation = saturation;
      _offTimer?.cancel();
      if (_activeCameras.isEmpty) {
        try {
          final current = await provider.read(light);
          _wasOn = current.on;
          if (!current.on) {
            if (light.colorDp != null && light.modeDp != null) {
              final color = HSVColor.fromAHSV(
                1,
                _motionHue,
                _motionSaturation,
                _motionBrightness / 100,
              ).toColor();
              await provider.setColor(
                light,
                (color.r * 255).round(),
                (color.g * 255).round(),
                (color.b * 255).round(),
              );
            } else if (light.brightnessDp != null) {
              await provider.setBrightness(light, _motionBrightness);
            }
            await provider.setPower(light, true);
          }
          onError(null);
        } catch (_) {
          _wasOn = null;
          rethrow;
        }
      }
      _activeCameras.add(cameraId);
      return;
    }
    if (!_activeCameras.remove(cameraId) || _activeCameras.isNotEmpty) {
      return;
    }
    if (_wasOn == false) {
      _offTimer?.cancel();
      _offTimer = Timer(_offDelay, () {
        unawaited(_turnOff());
      });
    } else {
      _wasOn = null;
    }
  });

  Future<void> _turnOff() async {
    try {
      await _serialize(() async {
        _offTimer = null;
        if (_activeCameras.isNotEmpty) return;
        if (_wasOn == false) await provider.setPower(light, false);
        _wasOn = null;
        onError(null);
      });
    } catch (error) {
      onError('${light.name}: ${friendlyError(error)}');
      if (_activeCameras.isEmpty) {
        _offTimer = Timer(_offDelay, () {
          unawaited(_turnOff());
        });
      }
    }
  }

  Future<void> shutdown() => _serialize(() async {
    _offTimer?.cancel();
    _offTimer = null;
    _activeCameras.clear();
    if (_wasOn == false) await provider.setPower(light, false);
    _wasOn = null;
  });
}

Future<void> runLightingService() async {
  WidgetsFlutterBinding.ensureInitialized();
  const vault = CredentialVault();
  final provider = TuyaLanLightProvider();
  final runner = LightingRunner(
    load: () async =>
        (await vault.readList('lights')).map(LightConfig.fromJson).toList(),
    send: (light, point) =>
        provider.setScheduledWhite(light, point.brightness, point.temperature),
  );
  final motionRunner = MotionLightingRunner(vault: vault, provider: provider);
  var pending = Future<void>.value();
  Future<T> serial<T>(Future<T> Function() action) async {
    final previous = pending;
    final gate = Completer<void>();
    pending = gate.future;
    await previous;
    try {
      return await action();
    } finally {
      gate.complete();
    }
  }

  Future<Map<String, Object>> control(String lightId, String action) async {
    final lights = await vault.readList('lights');
    final json = lights.where((light) => light['id'] == lightId).firstOrNull;
    if (json == null) {
      throw const HomeHubException(
        'This light was removed. Select another light for notification controls.',
      );
    }
    return provider.quickControl(LightConfig.fromJson(json), action);
  }

  LightingRuntime.channel.setMethodCallHandler((call) async {
    if (call.method != 'control') {
      throw MissingPluginException('Unknown lighting service command.');
    }
    final arguments = Map<String, dynamic>.from(call.arguments as Map);
    try {
      return await serial(
        () => control(
          arguments['lightId'] as String,
          arguments['action'] as String,
        ),
      );
    } catch (failure) {
      return {'error': friendlyError(failure)};
    }
  });
  await LightingRuntime.channel.invokeMethod<void>('ready');
  var lastScheduleRun = DateTime.fromMillisecondsSinceEpoch(0);
  while (true) {
    String? error;
    try {
      final configuration = await serial(
        () => LightingRuntime.channel.invokeMethod<Map<Object?, Object?>>(
          'configuration',
        ),
      );
      await motionRunner.sync(configuration?['motion'] == true);
      final now = DateTime.now();
      if (configuration?['schedules'] == true &&
          now.difference(lastScheduleRun) >= const Duration(seconds: 30)) {
        error = await serial(() => runner.tick(now));
        lastScheduleRun = now;
      }
    } catch (failure) {
      error = 'Cannot load background lighting. ${friendlyError(failure)}';
    }
    await LightingRuntime.channel.invokeMethod<void>('report', {
      'error': error,
      'motionError': motionRunner.error,
    });
    await Future<void>.delayed(const Duration(seconds: 1));
  }
}
