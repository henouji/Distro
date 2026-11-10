import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/local_network.dart';
import '../../core/storage.dart';
import '../lights/light.dart';
import '../lights/light_provider.dart';
import '../lights/lights_controller.dart';
import 'screen_capture.dart';
import 'tv_sync_engine.dart';

final screenCaptureProvider = Provider<ScreenCapture>(
  (ref) => AndroidScreenCapture(),
);
final lightStreamFactoryProvider = Provider<LightStream Function(LightConfig)>(
  (ref) => TuyaLightStream.new,
);
final tvSyncProvider = NotifierProvider<TvSyncController, TvSyncState>(
  TvSyncController.new,
);

enum TvSyncStatus { idle, starting, running }

class TvSyncState {
  const TvSyncState({
    this.status = TvSyncStatus.idle,
    this.settings = const SyncSettings(),
    this.lightId,
    this.mode,
    this.preview,
    this.error,
  });

  final TvSyncStatus status;
  final SyncSettings settings;
  final String? lightId, error;
  final SyncMode? mode;
  final LightFrame? preview;

  TvSyncState copyWith({
    TvSyncStatus? status,
    SyncSettings? settings,
    String? lightId,
    SyncMode? mode,
    LightFrame? preview,
    String? error,
    bool clearError = false,
    bool clearPreview = false,
  }) => TvSyncState(
    status: status ?? this.status,
    settings: settings ?? this.settings,
    lightId: lightId ?? this.lightId,
    mode: mode ?? this.mode,
    preview: clearPreview ? null : preview ?? this.preview,
    error: clearError ? null : error ?? this.error,
  );
}

class TvSyncController extends Notifier<TvSyncState> {
  static const _maxFailures = 6;

  int _session = 0;
  StreamSubscription<ScreenColor>? _frames;
  ScreenCapture? _capture;
  LightProvider? _lights;
  LightStream? _stream;
  LightConfig? _light;
  LightState? _previous;
  SyncEngine? _engine;
  SyncMode _mode = SyncMode.white;
  final _clock = Stopwatch();
  bool _busy = false;
  int _failures = 0;

  @override
  TvSyncState build() {
    ref.onDispose(() {
      _session++;
      unawaited(_teardown(restore: false));
    });
    final preferences = ref.read(preferencesProvider);
    return TvSyncState(
      lightId: preferences.getString('tvSync.lightId'),
      settings: SyncSettings(
        minBrightness: preferences.getDouble('tvSync.minBrightness') ?? 5,
        maxBrightness: preferences.getDouble('tvSync.maxBrightness') ?? 100,
        smoothing: preferences.getDouble('tvSync.smoothing') ?? .4,
      ),
    );
  }

  Future<void> selectLight(String id) async {
    if (state.status != TvSyncStatus.idle) return;
    await ref.read(preferencesProvider).setString('tvSync.lightId', id);
    state = state.copyWith(lightId: id, clearError: true, clearPreview: true);
  }

  Future<void> updateSettings(SyncSettings settings) async {
    state = state.copyWith(settings: settings);
    _engine?.settings = settings;
    final preferences = ref.read(preferencesProvider);
    await preferences.setDouble('tvSync.minBrightness', settings.minBrightness);
    await preferences.setDouble('tvSync.maxBrightness', settings.maxBrightness);
    await preferences.setDouble('tvSync.smoothing', settings.smoothing);
  }

  Future<void> start() async {
    if (state.status != TvSyncStatus.idle) return;
    final session = ++_session;
    state = state.copyWith(
      status: TvSyncStatus.starting,
      clearError: true,
      clearPreview: true,
    );
    try {
      final lights = await ref.read(lightsProvider.future);
      final light = lights
          .where((item) => item.id == state.lightId)
          .firstOrNull;
      if (light == null) {
        throw const HomeHubException('Choose a light to sync with the TV.');
      }
      light.validate();
      if (light.schedule?.enabled == true) {
        throw const HomeHubException(
          'Disable this light\'s dynamic lighting schedule before starting TV Sync.',
        );
      }
      _capture = ref.read(screenCaptureProvider);
      await _capture!.prepare();
      if (session != _session) return;
      _mode = syncModeFor(light);
      _light = light;
      _lights = ref.read(lightServiceProvider);
      try {
        _previous = await _lights!.read(light);
      } catch (_) {
        _previous = null;
      }
      if (session != _session) return;

      final stream = ref.read(lightStreamFactoryProvider)(light);
      _stream = stream;
      await stream.send(LightFrame.startDps(light, _mode), confirm: true);
      if (session != _session) return;

      _engine = SyncEngine(settings: state.settings);
      _failures = 0;
      _busy = false;
      _clock
        ..reset()
        ..start();
      _frames = _capture!.colors.listen(
        _onFrame,
        onError: (Object error) => _fail(session, error),
        onDone: () {
          if (session == _session) unawaited(stop());
        },
      );
      if (!await _capture!.start()) {
        throw const HomeHubException(
          'Screen capture was not allowed, so the light cannot follow the TV.',
        );
      }
      if (session != _session) return;
      state = state.copyWith(status: TvSyncStatus.running, mode: _mode);
    } catch (error) {
      if (session != _session) return;
      _session++;
      await _teardown(restore: true);
      if (ref.mounted) {
        state = state.copyWith(
          status: TvSyncStatus.idle,
          error: friendlyError(error),
        );
      }
    }
  }

  Future<void> stop() async {
    if (state.status == TvSyncStatus.idle) return;
    _session++;
    await _teardown(restore: true);
    if (ref.mounted) {
      state = state.copyWith(status: TvSyncStatus.idle, clearPreview: true);
    }
  }

  void _onFrame(ScreenColor color) {
    final engine = _engine, stream = _stream, light = _light;
    if (engine == null || stream == null || light == null) return;
    final frame = engine.next(color, _clock.elapsed, canSend: !_busy);
    if (frame == null) return;
    final session = _session;
    _busy = true;
    stream
        .send(frame.toDps(light, _mode))
        .then(
          (_) {
            _failures = 0;
            if (session == _session && ref.mounted) {
              state = state.copyWith(preview: frame);
            }
          },
          onError: (Object error) {
            if (++_failures >= _maxFailures) _fail(session, error);
          },
        )
        .whenComplete(() => _busy = false);
  }

  void _fail(int session, Object error) {
    if (session != _session) return;
    _session++;
    unawaited(
      _teardown(restore: false).whenComplete(() {
        if (ref.mounted) {
          state = state.copyWith(
            status: TvSyncStatus.idle,
            error: 'TV Sync stopped. ${friendlyError(error)}',
            clearPreview: true,
          );
        }
      }),
    );
  }

  Future<void> _teardown({required bool restore}) async {
    final frames = _frames, capture = _capture, stream = _stream;
    final light = _light, previous = _previous, lights = _lights;
    _frames = null;
    _stream = null;
    _engine = null;
    _light = null;
    _previous = null;
    _clock.stop();
    await frames?.cancel();
    try {
      await capture?.stop();
    } catch (_) {}
    try {
      await stream?.close();
    } catch (_) {}
    if (!restore || light == null || previous == null || lights == null) {
      return;
    }
    try {
      if (!previous.on) {
        await lights.setPower(light, false);
        return;
      }
      if (previous.hasBrightness) {
        await lights.setBrightness(light, previous.brightness);
      }
      if (previous.hasTemperature) {
        await lights.setTemperature(light, previous.temperature);
      }
    } catch (_) {}
  }
}
