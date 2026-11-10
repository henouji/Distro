import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/local_network.dart';

class TvApp {
  const TvApp({required this.package, required this.label, this.icon});
  final String package, label;
  final Uint8List? icon;
}

class ForegroundApp {
  const ForegroundApp({required this.usageAccess, this.package, this.label});
  final bool usageAccess;
  final String? package, label;
}

/// Native TV features: device type, installed apps and what is on screen.
abstract interface class TvPlatform {
  Future<bool> isTv();
  Future<List<TvApp>> listApps();
  Future<ForegroundApp> currentApp();
  Future<void> launchApp(String package);

  /// Sends HomeHub to the background instead of closing it.
  Future<void> moveToBack();
}

class AndroidTvPlatform implements TvPlatform {
  static const _channel = MethodChannel('homehub/tv');

  @override
  Future<bool> isTv() async {
    try {
      return await _channel.invokeMethod<bool>('isTv') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<List<TvApp>> listApps() async {
    final apps = await _call<List<Object?>>('listApps') ?? const [];
    return [
      for (final item in apps.whereType<Map<Object?, Object?>>())
        TvApp(
          package: item['package'] as String,
          label: item['label'] as String,
          icon: item['icon'] as Uint8List?,
        ),
    ];
  }

  @override
  Future<ForegroundApp> currentApp() async {
    final app = await _call<Map<Object?, Object?>>('currentApp');
    return ForegroundApp(
      usageAccess: app?['usageAccess'] == true,
      package: app?['package'] as String?,
      label: app?['label'] as String?,
    );
  }

  @override
  Future<void> launchApp(String package) =>
      _call<void>('launchApp', {'package': package});

  @override
  Future<void> moveToBack() => _call<void>('moveToBack');

  Future<T?> _call<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      throw const HomeHubException('This feature needs HomeHub on the TV.');
    } on PlatformException catch (error) {
      throw HomeHubException(error.message ?? 'The TV request failed.');
    }
  }
}

final tvPlatformProvider = Provider<TvPlatform>((ref) => AndroidTvPlatform());
final deviceIsTvProvider = FutureProvider<bool>(
  (ref) => ref.watch(tvPlatformProvider).isTv(),
);
