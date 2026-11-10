import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/components/glass.dart';
import '../../../core/local_network.dart';
import '../camera.dart';
import '../camera_ptz.dart';

class CameraControls extends ConsumerStatefulWidget {
  const CameraControls({super.key, required this.camera});
  final CameraConfig camera;

  @override
  ConsumerState<CameraControls> createState() => _CameraControlsState();
}

class _CameraControlsState extends ConsumerState<CameraControls> {
  late final PtzController _controller;
  bool _connected = false;
  bool _busy = false;
  bool _stopping = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(cameraPtzFactoryProvider)(widget.camera);
  }

  Future<void> _stop() async {
    setState(() => _stopping = true);
    try {
      await _controller.stop();
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _stopping = false);
    }
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool connect = false,
  }) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted && connect) setState(() => _connected = true);
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _direction(String label, IconData icon, double yaw, double pitch) =>
      IconButton.filledTonal(
        tooltip: label,
        onPressed: _connected && !_busy && !_stopping
            ? () => _run(() => _controller.nudge(yaw: yaw, pitch: pitch))
            : null,
        style: IconButton.styleFrom(fixedSize: const Size(56, 56)),
        icon: Icon(icon),
      );

  @override
  Widget build(BuildContext context) => GlassPanel(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Camera direction', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text(
          'Pitch & yaw',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        const Text(
          'Tap an arrow for a short movement. No absolute angle is reported.',
        ),
        const SizedBox(height: 20),
        Center(
          child: Column(
            children: [
              _direction('Tilt up (pitch)', Icons.keyboard_arrow_up, 0, 1),
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _direction(
                    'Pan left (yaw)',
                    Icons.keyboard_arrow_left,
                    -1,
                    0,
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 20),
                    child: Icon(Icons.control_camera, size: 32),
                  ),
                  _direction(
                    'Pan right (yaw)',
                    Icons.keyboard_arrow_right,
                    1,
                    0,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _direction('Tilt down (pitch)', Icons.keyboard_arrow_down, 0, -1),
            ],
          ),
        ),
        const SizedBox(height: 20),
        if (!_connected)
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run(_controller.connect, connect: true),
              icon: const Icon(Icons.link),
              label: Text(_busy ? 'Connecting...' : 'Connect controls'),
            ),
          )
        else
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _stopping ? null : _stop,
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('Stop movement'),
            ),
          ),
        if (_busy) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          _connected ? 'ONVIF connected / local control' : 'Tapo C200 / ONVIF',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );
}
