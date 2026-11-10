import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/navigation.dart';
import '../camera.dart';

class CameraPlayer extends StatefulWidget {
  const CameraPlayer({super.key, required this.camera, this.preview = false});
  final CameraConfig camera;
  final bool preview;

  @override
  State<CameraPlayer> createState() => _CameraPlayerState();
}

class _CameraPlayerState extends State<CameraPlayer>
    with WidgetsBindingObserver, RouteAware {
  Player? _player;
  VideoController? _video;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Timer? _timeout;
  Timer? _stallTimeout;
  String? _error;
  bool _ready = false;
  bool _muted = true;
  bool _foreground = true;
  bool _routeVisible = true;
  int _generation = 0;
  int _restartVersion = 0;
  ModalRoute<void>? _route;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _open();
  }

  void _open() {
    final generation = ++_generation;
    _ready = false;
    _error = null;
    final player = Player(
      configuration: const PlayerConfiguration(
        logLevel: MPVLogLevel.error,
        bufferSize: 4 * 1024 * 1024,
      ),
    );
    _player = player;
    _video = VideoController(player);
    _subscriptions.add(
      player.stream.error.listen((_) {
        if (mounted && generation == _generation) {
          _fail(
            'Cannot play this camera. Check the camera account, RTSP setting and Wi-Fi.',
          );
        }
      }),
    );
    _subscriptions.add(
      player.stream.width.listen((width) {
        if (width != null &&
            width > 0 &&
            mounted &&
            generation == _generation) {
          _timeout?.cancel();
          setState(() {
            _ready = true;
            _error = null;
          });
        }
      }),
    );
    _subscriptions.add(
      player.stream.completed.listen((completed) {
        if (completed && mounted && generation == _generation) {
          _fail('The camera stream ended. Retry to reconnect.');
        }
      }),
    );
    _subscriptions.add(
      player.stream.buffering.listen((buffering) {
        if (!mounted || generation != _generation) return;
        _stallTimeout?.cancel();
        if (buffering && _ready) {
          _stallTimeout = Timer(const Duration(seconds: 15), () {
            if (mounted && generation == _generation) {
              _fail('Camera stream stalled. Retry to reconnect.');
            }
          });
        }
      }),
    );
    _timeout = Timer(const Duration(seconds: 15), () {
      if (mounted && generation == _generation && !_ready) {
        _fail(
          'Camera timed out. Check its address and that you are on the same Wi-Fi.',
        );
      }
    });
    unawaited(_start(player, generation));
  }

  Future<void> _start(Player player, int generation) async {
    try {
      final platform = player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('rtsp-transport', 'tcp');
        await platform.setProperty('network-timeout', '10');
      }
      if (generation != _generation) return;
      await player.setVolume(_muted ? 0 : 100);
      await player.open(Media(widget.camera.rtspUrl(preview: widget.preview)));
    } catch (_) {
      if (mounted && generation == _generation) {
        _fail(
          'Camera connection failed. Check the address and camera-account credentials.',
        );
      }
    }
  }

  void _fail(String message) {
    _timeout?.cancel();
    setState(() {
      _error = message;
      _ready = false;
    });
    unawaited(_release());
  }

  Future<void> _release() async {
    _generation++;
    _timeout?.cancel();
    _stallTimeout?.cancel();
    final subscriptions = List<StreamSubscription<dynamic>>.of(_subscriptions);
    _subscriptions.clear();
    final player = _player;
    _player = null;
    _video = null;
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    await player?.dispose();
  }

  Future<void> _retry() async {
    final restart = ++_restartVersion;
    await _release();
    if (mounted && _foreground && _routeVisible && restart == _restartVersion) {
      setState(_open);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of<void>(context);
    if (_route != route) {
      cameraRouteObserver.unsubscribe(this);
      _route = route;
      if (route != null) cameraRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    _routeVisible = false;
    unawaited(_release());
  }

  @override
  void didPopNext() {
    _routeVisible = true;
    unawaited(_retry());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      unawaited(_retry());
    } else {
      setState(() {
        _ready = false;
      });
      unawaited(_release());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    cameraRouteObserver.unsubscribe(this);
    unawaited(_release());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: Stack(
      fit: StackFit.expand,
      children: [
        if (_video != null)
          Video(
            controller: _video!,
            controls: NoVideoControls,
            fit: BoxFit.contain,
          ),
        if (_error != null)
          Center(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.videocam_off_outlined,
                      color: Colors.white70,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: widget.preview ? 12 : 16,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _retry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (!_ready && _error == null)
          const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        if (_ready && !widget.preview)
          Positioned(
            right: 16,
            bottom: 16,
            child: IconButton.filled(
              tooltip: _muted ? 'Unmute camera' : 'Mute camera',
              onPressed: () async {
                try {
                  final muted = !_muted;
                  await _player?.setVolume(muted ? 0 : 100);
                  if (mounted) {
                    setState(() {
                      _muted = muted;
                    });
                  }
                } catch (_) {
                  if (mounted) {
                    _fail('Audio could not be changed. Retry the stream.');
                  }
                }
              },
              icon: Icon(_muted ? Icons.volume_off : Icons.volume_up),
            ),
          ),
      ],
    ),
  );
}
