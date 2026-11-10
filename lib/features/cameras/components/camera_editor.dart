import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/components/feedback.dart';
import '../../../core/local_network.dart';
import '../camera.dart';
import '../camera_controller.dart';
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
  String? _error;

  @override
  void initState() {
    super.initState();
    final camera = widget.camera;
    _stream = camera?.stream ?? CameraStream.stream1;
    _panTilt = camera?.panTilt ?? false;
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
            if (_panTilt)
              DeviceField(
                controller: _fields['ONVIF port']!,
                label: 'ONVIF port',
                numeric: true,
                enabled: !_busy,
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
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
}
