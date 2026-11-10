import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/local_network.dart';
import '../../../core/storage.dart';
import '../../lights/light.dart';
import '../../lights/lights_controller.dart';
import '../tv_platform.dart';
import '../tv_sync_controller.dart';
import '../tv_sync_engine.dart';
import 'tv_remote_protocol.dart';

final tvRemoteHostPortProvider = Provider<int>((ref) => tvRemotePort);
final tvRemoteHostProvider =
    NotifierProvider<TvRemoteHost, TvRemoteHostState>(TvRemoteHost.new);

class TvRemoteHostState {
  const TvRemoteHostState({
    this.enabled = false,
    this.running = false,
    this.address,
    this.port,
    this.pairingCode,
    this.paired = 0,
    this.error,
  });

  final bool enabled, running;
  final String? address, pairingCode, error;
  final int? port;

  /// Number of tablets allowed to control this TV.
  final int paired;

  TvRemoteHostState withCode(String code, {int? paired}) => TvRemoteHostState(
    enabled: enabled,
    running: running,
    address: address,
    port: port,
    pairingCode: code,
    paired: paired ?? this.paired,
    error: error,
  );
}

class _HttpError implements Exception {
  const _HttpError(this.status, this.message);
  final int status;
  final String message;
}

/// Runs on the TV: lets paired tablets on the home network see what is
/// playing, open apps and control TV Sync.
class TvRemoteHost extends Notifier<TvRemoteHostState> {
  static const _tokensKey = 'tvRemoteTokens';
  static const _enabledKey = 'tvRemote.enabled';
  static const _maxBody = 512 * 1024;

  final _random = Random.secure();
  HttpServer? _server;
  Set<String> _tokens = {};
  int _failures = 0;

  @override
  TvRemoteHostState build() {
    ref.onDispose(() {
      unawaited(_server?.close(force: true));
      _server = null;
    });
    final enabled = ref.read(preferencesProvider).getBool(_enabledKey) ?? false;
    if (enabled) Future.microtask(_start);
    return TvRemoteHostState(enabled: enabled);
  }

  Future<void> setEnabled(bool enabled) async {
    await ref.read(preferencesProvider).setBool(_enabledKey, enabled);
    if (enabled) {
      state = const TvRemoteHostState(enabled: true);
      await _start();
    } else {
      final server = _server;
      _server = null;
      state = const TvRemoteHostState();
      await server?.close(force: true);
    }
  }

  Future<void> forgetTablets() async {
    await ref.read(vaultProvider).writeList(_tokensKey, []);
    _tokens = {};
    state = state.withCode(_newCode(), paired: 0);
  }

  Future<void> _start() async {
    if (_server != null) return;
    try {
      final saved = await ref.read(vaultProvider).readList(_tokensKey);
      final server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        ref.read(tvRemoteHostPortProvider),
      );
      if (!ref.mounted || !state.enabled || _server != null) {
        await server.close(force: true);
        return;
      }
      _server = server;
      _tokens = {for (final item in saved) item['hash'] as String};
      server.listen(_handle, onError: (Object _) {});
      state = TvRemoteHostState(
        enabled: true,
        running: true,
        address: await _localAddress(),
        port: server.port,
        pairingCode: _newCode(),
        paired: _tokens.length,
      );
    } catch (error) {
      if (ref.mounted && state.enabled) {
        state = TvRemoteHostState(
          enabled: true,
          error: 'Tablet control could not start on this TV ($error).',
        );
      }
    }
  }

  String _newCode() => _random.nextInt(1000000).toString().padLeft(6, '0');

  static Future<String?> _localAddress() async {
    try {
      for (final interface in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      )) {
        for (final address in interface.addresses) {
          if (isPrivateIpv4(address.address)) return address.address;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _handle(HttpRequest request) async {
    var status = HttpStatus.ok;
    Object body;
    try {
      final remote = request.connectionInfo?.remoteAddress;
      if (remote == null ||
          !(remote.isLoopback || isPrivateIpv4(remote.address))) {
        throw const _HttpError(
          HttpStatus.forbidden,
          'Only devices on your home network can control the TV.',
        );
      }
      final route = '${request.method} ${request.uri.path}';
      if (route == 'POST /pair') {
        body = await _pair(await _json(request));
      } else {
        _authorize(request);
        body = await _route(route, request);
      }
    } on _HttpError catch (error) {
      status = error.status;
      body = {'error': error.message};
    } on HomeHubException catch (error) {
      status = HttpStatus.badRequest;
      body = {'error': error.message};
    } on FormatException {
      status = HttpStatus.badRequest;
      body = {'error': 'The TV could not read that request.'};
    } catch (_) {
      status = HttpStatus.internalServerError;
      body = {'error': 'The TV could not complete that request.'};
    }
    try {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await request.response.close();
    } catch (_) {}
  }

  Future<Object> _route(String route, HttpRequest request) async {
    final sync = ref.read(tvSyncProvider.notifier);
    final platform = ref.read(tvPlatformProvider);
    switch (route) {
      case 'GET /state':
        break;
      case 'GET /apps':
        return {
          'apps': [for (final app in await platform.listApps()) tvAppToJson(app)],
        };
      case 'POST /apps/launch':
        final package = (await _json(request))['package'];
        if (package is! String || package.isEmpty) {
          throw const HomeHubException('Choose an app to open.');
        }
        await platform.launchApp(package);
      case 'POST /sync/start':
        final lightId = (await _json(request))['lightId'];
        if (lightId is String) await _selectLight(lightId);
        await sync.start();
      case 'POST /sync/stop':
        await sync.stop();
      case 'PUT /sync/light':
        final lightId = (await _json(request))['lightId'];
        if (lightId is! String) {
          throw const HomeHubException('Choose a light to sync with the TV.');
        }
        await _selectLight(lightId);
      case 'PUT /sync/settings':
        final json = await _json(request);
        double percent(String key, double max) {
          final value = json[key];
          if (value is! num || !value.isFinite) {
            throw const HomeHubException('Check the TV Sync settings.');
          }
          return value.toDouble().clamp(0, max).toDouble();
        }
        await sync.updateSettings(
          SyncSettings(
            minBrightness: percent('minBrightness', 100),
            maxBrightness: percent('maxBrightness', 100),
            smoothing: percent('smoothing', 1),
          ),
        );
      case 'PUT /lights':
        final items = (await _json(request))['lights'];
        if (items is! List) {
          throw const HomeHubException('No lights were sent to the TV.');
        }
        final lights = [
          for (final item in items)
            LightConfig.fromJson(Map<String, dynamic>.from(item as Map))
              ..validate(),
        ];
        final controller = ref.read(lightsProvider.notifier);
        for (final light in lights) {
          await controller.save(light);
        }
      default:
        throw const _HttpError(HttpStatus.notFound, 'Unknown TV request.');
    }
    return _snapshot();
  }

  Future<void> _selectLight(String id) async {
    final lights = await ref.read(lightsProvider.future);
    if (!lights.any((light) => light.id == id)) {
      throw const HomeHubException(
        'That light is not set up on the TV. Send your lights to the TV first.',
      );
    }
    await ref.read(tvSyncProvider.notifier).selectLight(id);
  }

  Future<Map<String, dynamic>> _snapshot() async {
    final lights = await ref.read(lightsProvider.future);
    ForegroundApp app;
    try {
      app = await ref.read(tvPlatformProvider).currentApp();
    } catch (_) {
      app = const ForegroundApp(usageAccess: false);
    }
    SyncMode? modeOf(LightConfig light) {
      try {
        return syncModeFor(light);
      } catch (_) {
        return null;
      }
    }

    return TvRemoteSnapshot.fromSync(
      'TV',
      ref.read(tvSyncProvider),
      [
        for (final light in lights)
          RemoteLight(id: light.id, name: light.name, mode: modeOf(light)),
      ],
      app,
    ).toJson();
  }

  void _authorize(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    final token = header != null && header.startsWith('Bearer ')
        ? header.substring(7)
        : null;
    if (token == null || !_tokens.contains(_hash(token))) {
      throw const _HttpError(
        HttpStatus.unauthorized,
        'This tablet is not paired with the TV.',
      );
    }
  }

  Future<Map<String, dynamic>> _pair(Map<String, dynamic> json) async {
    final code = state.pairingCode;
    if (code == null || json['code'] != code) {
      if (++_failures >= 5) {
        _failures = 0;
        state = state.withCode(_newCode());
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      throw const _HttpError(
        HttpStatus.forbidden,
        'Wrong pairing code. Use the code shown on the TV.',
      );
    }
    _failures = 0;
    final token = base64UrlEncode(
      Uint8List.fromList(List.generate(32, (_) => _random.nextInt(256))),
    );
    final name = '${json['name'] ?? 'Tablet'}'.trim();
    final hash = _hash(token);
    final vault = ref.read(vaultProvider);
    await vault.writeList(_tokensKey, [
      ...await vault.readList(_tokensKey),
      {
        'hash': hash,
        'name': name.substring(0, min(name.length, 40)),
      },
    ]);
    _tokens.add(hash);
    state = state.withCode(_newCode(), paired: _tokens.length);
    return {'token': token, 'name': 'TV'};
  }

  static String _hash(String token) =>
      sha256.convert(utf8.encode(token)).toString();

  static Future<Map<String, dynamic>> _json(HttpRequest request) async {
    if (request.contentLength > _maxBody) {
      throw const _HttpError(
        HttpStatus.requestEntityTooLarge,
        'Request too large.',
      );
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in request) {
      bytes.add(chunk);
      if (bytes.length > _maxBody) {
        throw const _HttpError(
          HttpStatus.requestEntityTooLarge,
          'Request too large.',
        );
      }
    }
    if (bytes.isEmpty) return {};
    final value = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (value is! Map) throw const FormatException('Expected an object.');
    return Map<String, dynamic>.from(value);
  }
}
