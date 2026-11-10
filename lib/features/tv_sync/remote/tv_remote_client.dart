import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/local_network.dart';
import '../../../core/storage.dart';
import '../../lights/light.dart';
import '../tv_platform.dart';
import '../tv_sync_engine.dart';
import 'tv_remote_protocol.dart';

class PairedTv {
  const PairedTv({
    required this.host,
    required this.token,
    this.port = tvRemotePort,
    this.name = 'TV',
  });

  final String host, token, name;
  final int port;

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'token': token,
    'name': name,
  };

  factory PairedTv.fromJson(Map<String, dynamic> json) => PairedTv(
    host: json['host'] as String,
    port: json['port'] as int? ?? tvRemotePort,
    token: json['token'] as String,
    name: json['name'] as String? ?? 'TV',
  );
}

/// What the tablet can do with a paired TV.
abstract interface class TvRemoteApi {
  Future<TvRemoteSnapshot> state();
  Future<List<TvApp>> apps();
  Future<TvRemoteSnapshot> launch(String package);
  Future<TvRemoteSnapshot> startSync({String? lightId});
  Future<TvRemoteSnapshot> stopSync();
  Future<TvRemoteSnapshot> selectLight(String lightId);
  Future<TvRemoteSnapshot> updateSettings(SyncSettings settings);
  Future<TvRemoteSnapshot> sendLights(List<LightConfig> lights);
}

class TvRemoteClient implements TvRemoteApi {
  TvRemoteClient(this.tv);
  final PairedTv tv;

  static Future<PairedTv> pair(
    String host,
    String code, {
    int port = tvRemotePort,
  }) async {
    final json = await _send(
      host,
      port,
      'POST',
      '/pair',
      body: {'code': code, 'name': 'Tablet'},
    );
    return PairedTv(
      host: host,
      port: port,
      token: json['token'] as String,
      name: json['name'] as String? ?? 'TV',
    );
  }

  Future<TvRemoteSnapshot> _snapshot(
    String method,
    String path, {
    Object? body,
    Duration timeout = const Duration(seconds: 8),
  }) async => TvRemoteSnapshot.fromJson(
    await _send(
      tv.host,
      tv.port,
      method,
      path,
      token: tv.token,
      body: body,
      timeout: timeout,
    ),
  );

  @override
  Future<TvRemoteSnapshot> state() => _snapshot('GET', '/state');

  @override
  Future<List<TvApp>> apps() async {
    final json = await _send(
      tv.host,
      tv.port,
      'GET',
      '/apps',
      token: tv.token,
      timeout: const Duration(seconds: 20),
    );
    return [
      for (final app in json['apps'] as List)
        tvAppFromJson(Map<String, dynamic>.from(app as Map)),
    ];
  }

  @override
  Future<TvRemoteSnapshot> launch(String package) =>
      _snapshot('POST', '/apps/launch', body: {'package': package});

  // Starting may wait for someone to accept the capture prompt on the TV.
  @override
  Future<TvRemoteSnapshot> startSync({String? lightId}) => _snapshot(
    'POST',
    '/sync/start',
    body: {'lightId': ?lightId},
    timeout: const Duration(seconds: 60),
  );

  @override
  Future<TvRemoteSnapshot> stopSync() =>
      _snapshot('POST', '/sync/stop', timeout: const Duration(seconds: 20));

  @override
  Future<TvRemoteSnapshot> selectLight(String lightId) =>
      _snapshot('PUT', '/sync/light', body: {'lightId': lightId});

  @override
  Future<TvRemoteSnapshot> updateSettings(SyncSettings settings) => _snapshot(
    'PUT',
    '/sync/settings',
    body: {
      'minBrightness': settings.minBrightness,
      'maxBrightness': settings.maxBrightness,
      'smoothing': settings.smoothing,
    },
  );

  @override
  Future<TvRemoteSnapshot> sendLights(List<LightConfig> lights) => _snapshot(
    'PUT',
    '/lights',
    body: {'lights': [for (final light in lights) light.toJson()]},
  );

  static Future<Map<String, dynamic>> _send(
    String host,
    int port,
    String method,
    String path, {
    String? token,
    Object? body,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (host != '127.0.0.1') requireLocalAddress(host);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      return await () async {
        final request = await client.openUrl(
          method,
          Uri(scheme: 'http', host: host, port: port, path: path),
        );
        if (token != null) {
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        }
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final response = await request.close();
        final text = await utf8.decodeStream(response);
        final decoded = text.isEmpty ? const {} : jsonDecode(text);
        final json = decoded is Map
            ? Map<String, dynamic>.from(decoded)
            : <String, dynamic>{};
        if (response.statusCode == HttpStatus.unauthorized) {
          throw const HomeHubException(
            'This tablet is no longer paired with the TV. Pair it again.',
          );
        }
        if (response.statusCode != HttpStatus.ok) {
          throw HomeHubException(
            json['error'] as String? ?? 'The TV rejected the request.',
          );
        }
        return json;
      }().timeout(timeout);
    } on HomeHubException {
      rethrow;
    } on TimeoutException {
      throw const HomeHubException(
        'The TV did not answer in time. Check that HomeHub is open on the TV.',
      );
    } catch (_) {
      throw const HomeHubException(
        'Cannot reach the TV. Check its IP, that both devices share the Wi-Fi, '
        'and that tablet control is on in HomeHub on the TV.',
      );
    } finally {
      client.close(force: true);
    }
  }
}

final tvPairingProvider =
    Provider<Future<PairedTv> Function(String host, String code)>(
      (ref) => TvRemoteClient.pair,
    );
final tvRemoteApiFactoryProvider = Provider<TvRemoteApi Function(PairedTv)>(
  (ref) => TvRemoteClient.new,
);
final pairedTvProvider = AsyncNotifierProvider<PairedTvController, PairedTv?>(
  PairedTvController.new,
);

class PairedTvController extends AsyncNotifier<PairedTv?> {
  static const _key = 'pairedTv';

  @override
  Future<PairedTv?> build() async {
    final saved = await ref.watch(vaultProvider).readList(_key);
    return saved.isEmpty ? null : PairedTv.fromJson(saved.first);
  }

  Future<void> pair(String host, String code) async {
    host = host.trim();
    code = code.trim();
    requireLocalAddress(host);
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      throw const HomeHubException('Enter the 6-digit code shown on the TV.');
    }
    final tv = await ref.read(tvPairingProvider)(host, code);
    await ref.read(vaultProvider).writeList(_key, [tv.toJson()]);
    state = AsyncData(tv);
  }

  Future<void> forget() async {
    await ref.read(vaultProvider).writeList(_key, []);
    state = const AsyncData(null);
  }
}

TvRemoteApi? _api(Ref ref) {
  final tv = ref.watch(pairedTvProvider).value;
  return tv == null ? null : ref.watch(tvRemoteApiFactoryProvider)(tv);
}

/// Live TV state, refreshed every two seconds while the TV screen is open.
final tvRemoteStateProvider = StreamProvider.autoDispose<TvRemoteSnapshot>((
  ref,
) {
  final api = _api(ref);
  if (api == null) return const Stream.empty();
  final controller = StreamController<TvRemoteSnapshot>();
  Timer? timer;
  var closed = false;
  Future<void> poll() async {
    try {
      final snapshot = await api.state();
      if (!closed) controller.add(snapshot);
    } catch (error, stack) {
      if (!closed) controller.addError(error, stack);
    }
    if (!closed) timer = Timer(const Duration(seconds: 2), poll);
  }

  unawaited(poll());
  ref.onDispose(() {
    closed = true;
    timer?.cancel();
    unawaited(controller.close());
  });
  return controller.stream;
});

final tvAppsProvider = FutureProvider.autoDispose<List<TvApp>>((ref) async {
  final api = _api(ref);
  return api == null ? const [] : api.apps();
});

final tvRemoteApiProvider = Provider.autoDispose<TvRemoteApi?>(_api);
