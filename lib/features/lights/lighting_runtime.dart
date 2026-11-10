import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../core/local_network.dart';
import '../../core/storage.dart';
import 'light.dart';
import 'light_provider.dart';
import 'light_schedule.dart';

class LightingRuntime {
  static const channel = MethodChannel('homehub/lighting');

  Future<void> start() => channel.invokeMethod<void>('start');
  Future<void> stop() => channel.invokeMethod<void>('stop');
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
  while (true) {
    String? error;
    try {
      error = await serial(() async {
        final configuration = await LightingRuntime.channel
            .invokeMethod<Map<Object?, Object?>>('configuration');
        return configuration?['schedules'] == true
            ? runner.tick(DateTime.now())
            : null;
      });
    } catch (failure) {
      error = 'Cannot load lighting schedules. ${friendlyError(failure)}';
    }
    await LightingRuntime.channel.invokeMethod<void>('report', {
      'error': error,
    });
    await Future<void>.delayed(const Duration(seconds: 30));
  }
}
