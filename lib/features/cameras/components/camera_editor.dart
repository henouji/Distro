import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/components/feedback.dart';
import '../../../core/local_network.dart';
import '../../lights/lights_controller.dart';
import '../camera.dart';
import '../camera_controller.dart';
import '../camera_events.dart';
import '../../lights/components/color_wheel.dart';
import 'camera_view.dart';

class CameraEditor extends ConsumerStatefulWidget {
  const CameraEditor({super.key, this.camera});
  final CameraConfig? camera;
  @override
  ConsumerState<CameraEditor> createState() => _CameraEditorState();
}

class _CameraEditorState extends ConsumerState<CameraEditor> {
  final _form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _fields;
  CameraStream _stream = CameraStream.stream1;
  bool _busy = false;
  bool _panTilt = false;
  String? _motionLightId;
  late double _motionBrightness, _motionHue, _motionSaturation;
  late int _motionOffDelaySeconds;
  String? _error;
  bool _testingMotion = false;
  String? _motionResult;

  @override
  void initState() {
    super.initState();
    final camera = widget.camera;
    _stream = camera?.stream ?? CameraStream.stream1;
    _panTilt = camera?.panTilt ?? false;
    _motionLightId = camera?.motionLightId;
    _motionBrightness = camera?.motionBrightness ?? 100;
    _motionHue = camera?.motionHue ?? 0;
    _motionSaturation = camera?.motionSaturation ?? 1;
    _motionOffDelaySeconds = camera?.motionOffDelaySeconds ?? 20;
    _fields = {
      'Name': TextEditingController(text: camera?.name ?? ''),
      'Private IP address': TextEditingController(text: camera?.host ?? ''),
      'RTSP port': TextEditingController(text: '${camera?.port ?? 554}'),
      'ONVIF port': TextEditingController(text: '${camera?.onvifPort ?? 2020}'),
      'Camera username': TextEditingController(text: camera?.username ?? ''),
      'Camera password': TextEditingController(text: camera?.password ?? ''),
    };
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  CameraConfig _config() => CameraConfig(
    id: widget.camera?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
    name: _fields['Name']!.text.trim(),
    host: _fields['Private IP address']!.text.trim(),
    username: _fields['Camera username']!.text,
    password: _fields['Camera password']!.text,
    port: int.tryParse(_fields['RTSP port']!.text.trim()) ?? 0,
    stream: _stream,
    panTilt: _panTilt,
    onvifPort: int.tryParse(_fields['ONVIF port']!.text.trim()) ?? 0,
    motionLightId: _motionLightId,
    motionBrightness: _motionBrightness,
    motionHue: _motionHue,
    motionSaturation: _motionSaturation,
    motionOffDelaySeconds: _motionOffDelaySeconds,
  );

  Future<void> _submit({bool test = false}) async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final camera = _config();
      camera.validate();
      if (test) {
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => CameraView(camera: camera, testing: true),
          ),
        );
      } else {
        if (_motionLightId != null) {
          final lights = ref.read(lightsProvider).asData?.value;
          final light = lights
              ?.where((item) => item.id == _motionLightId)
              .firstOrNull;
          if (light == null) {
            throw const HomeHubException(
              'Could not load the selected motion light. Retry from the Lights screen.',
            );
          }
        }
        await ref.read(camerasProvider.notifier).save(camera);
        if (mounted) Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = friendlyError(error);
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _testMotionEvents() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _testingMotion = true;
      _motionResult = 'Move in front of the camera while the test listens.';
    });
    try {
      final camera = _config();
      final result = await OnvifMotionProbe(camera).listenForMotion();
      if (mounted) {
        setState(() {
          _motionResult = result.motionObserved
              ? 'ONVIF motion event received. This camera can trigger motion-based lighting.'
              : 'ONVIF events are available, but no motion event arrived. Move in front of the camera and test again.';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _motionResult = friendlyError(error);
        });
      }
    } finally {
      if (mounted) setState(() => _testingMotion = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.camera == null ? 'Add Camera' : 'Edit Camera'),
    ),
    body: Form(
      key: _form,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final entry in _fields.entries.where(
              (entry) => entry.key != 'ONVIF port',
            ))
              DeviceField(
                controller: entry.value,
                label: entry.key,
                enabled: !_busy,
                secret: entry.key == 'Camera password',
                numeric: entry.key == 'RTSP port',
              ),
            DropdownButtonFormField<CameraStream>(
              initialValue: _stream,
              decoration: const InputDecoration(
                labelText: 'Full-screen quality',
              ),
              items: const [
                DropdownMenuItem(
                  value: CameraStream.stream1,
                  child: Text('High (stream1)'),
                ),
                DropdownMenuItem(
                  value: CameraStream.stream2,
                  child: Text('Low (stream2)'),
                ),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                      _stream = value!;
                    }),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('ONVIF pan / tilt'),
              subtitle: const Text(
                'Move a Tapo C200 over your LAN using its camera account, '
                'not your TP-Link cloud login.',
              ),
              value: _panTilt,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _panTilt = value),
            ),
            if (_panTilt || _motionLightId != null)
              DeviceField(
                controller: _fields['ONVIF port']!,
                label: 'ONVIF port',
                numeric: true,
                enabled: !_busy,
              ),
            const SizedBox(height: 16),
            Text(
              'Motion-triggered light',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text(
              'Turn the selected Tuya light on when the camera detects motion. '
              'Choose a color, brightness and no-motion off delay. Monitoring runs in a '
              'foreground service with a persistent notification.',
            ),
            const SizedBox(height: 8),
            _motionLightSelector(),
            if (_motionLightId != null) _motionLightSettings(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (widget.camera != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy || _testingMotion ? null : _testMotionEvents,
                icon: _testingMotion
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sensors_outlined),
                label: Text(
                  _testingMotion
                      ? 'Listening for motion...'
                      : 'Test motion events',
                ),
              ),
              if (_motionResult != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_motionResult!),
                ),
              if (!_testingMotion && _motionResult == null)
                const Text(
                  'Listens for 20 seconds. Move in front of the camera. '
                  'This test does not control lights.',
                ),
            ],
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _submit(test: true),
              icon: const Icon(Icons.videocam_outlined),
              label: const Text('Test connection'),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : _submit,
              icon: const Icon(Icons.save_outlined),
              label: Text(_busy ? 'Please wait...' : 'Save Camera'),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _motionLightSelector() {
    final lights = ref.watch(lightsProvider);
    final configuredLights = lights.asData?.value;
    if (configuredLights == null) {
      return Text(
        lights.hasError
            ? 'Could not load lights. Retry from the Lights screen.'
            : 'Loading configured lights...',
      );
    }
    final selectedExists = configuredLights.any(
      (light) => light.id == _motionLightId,
    );
    return DropdownButtonFormField<String?>(
      initialValue: _motionLightId,
      decoration: const InputDecoration(labelText: 'Light for motion'),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('Disabled')),
        if (_motionLightId != null && !selectedExists)
          DropdownMenuItem<String?>(
            value: _motionLightId,
            child: const Text('Unavailable light — choose another'),
          ),
        for (final light in configuredLights)
          DropdownMenuItem<String?>(value: light.id, child: Text(light.name)),
      ],
      onChanged: _busy
          ? null
          : (value) => setState(() {
              _motionLightId = value;
            }),
    );
  }

  Widget _motionLightSettings() {
    final selected = ref
        .watch(lightsProvider)
        .asData
        ?.value
        .where((light) => light.id == _motionLightId)
        .firstOrNull;
    if (selected == null) return const SizedBox.shrink();
    final supportsColor = selected.modeDp != null && selected.colorDp != null;
    final supportsBrightness = supportsColor || selected.brightnessDp != null;
    final color = HSVColor.fromAHSV(1, _motionHue, _motionSaturation, 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        if (supportsColor) ...[
          Text('Motion color', style: Theme.of(context).textTheme.titleSmall),
          Center(
            child: ColorWheel(
              color: color,
              onChanged: _busy
                  ? (_) {}
                  : (value) => setState(() {
                      _motionHue = value.hue;
                      _motionSaturation = value.saturation;
                    }),
            ),
          ),
          Container(
            height: 36,
            decoration: BoxDecoration(
              color: color.withValue(_motionBrightness / 100).toColor(),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ] else
          Text(
            supportsBrightness
                ? 'Color control is not configured for this light; motion will use white mode and the selected brightness.'
                : 'Color and brightness control are not configured; motion will only turn the light on and off.',
          ),
        if (supportsBrightness) ...[
          Text('Brightness ${_motionBrightness.round()}%'),
          Slider(
            value: _motionBrightness,
            max: 100,
            semanticFormatterCallback: (value) =>
                '${value.round()} percent brightness',
            onChanged: _busy
                ? null
                : (value) => setState(() => _motionBrightness = value),
          ),
        ],
        Text('Turn off after $_motionOffDelaySeconds seconds without motion'),
        Slider(
          value: _motionOffDelaySeconds.toDouble(),
          min: 1,
          max: 300,
          divisions: 299,
          semanticFormatterCallback: (value) =>
              '${value.round()} seconds without motion',
          onChanged: _busy
              ? null
              : (value) =>
                    setState(() => _motionOffDelaySeconds = value.round()),
        ),
      ],
    );
  }
}
