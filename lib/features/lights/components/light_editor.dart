import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/components/feedback.dart';
import '../../../core/local_network.dart';
import '../light.dart';
import '../lights_controller.dart';

class LightEditor extends ConsumerStatefulWidget {
  const LightEditor({super.key, this.config});
  final LightConfig? config;
  @override
  ConsumerState<LightEditor> createState() => _LightEditorState();
}

class _LightEditorState extends ConsumerState<LightEditor> {
  final _form = GlobalKey<FormState>();
  final _fields = <String, TextEditingController>{};
  double _version = 3.3;
  DpProfile _profile = DpProfile.modern;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final config = widget.config;
    _version = config?.version ?? 3.3;
    _profile = config?.profile ?? DpProfile.modern;
    final values = <String, String>{
      'Name': config?.name ?? '',
      'Device ID': config?.id ?? '',
      'Private IP address': config?.host ?? '',
      'Local key': config?.localKey ?? '',
      'Power DP': '${config?.switchDp ?? 20}',
      'Mode DP': config == null ? '21' : '${config.modeDp ?? ''}',
      'Brightness DP': config == null ? '22' : '${config.brightnessDp ?? ''}',
      'Temperature DP': config == null ? '23' : '${config.temperatureDp ?? ''}',
      'Color DP': '${config?.colorDp ?? ''}',
      'Brightness minimum': '${config?.brightnessMin ?? 10}',
      'Value maximum': '${config?.valueMax ?? 1000}',
    };
    for (final entry in values.entries) {
      _fields[entry.key] = TextEditingController(text: entry.value);
    }
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String _text(String key) => _fields[key]!.text.trim();
  int? _optionalInt(String key) {
    final value = _text(key);
    if (value.isEmpty) return null;
    final parsed = int.tryParse(value);
    if (parsed == null) {
      throw HomeHubException('$key must be a whole number or empty.');
    }
    return parsed;
  }

  LightConfig _config() => LightConfig(
    id: _text('Device ID'),
    name: _text('Name'),
    host: _text('Private IP address'),
    localKey: _fields['Local key']!.text,
    version: _version,
    profile: _profile,
    switchDp: _optionalInt('Power DP') ?? 0,
    modeDp: _optionalInt('Mode DP'),
    brightnessDp: _optionalInt('Brightness DP'),
    temperatureDp: _optionalInt('Temperature DP'),
    colorDp: _optionalInt('Color DP'),
    brightnessMin: _optionalInt('Brightness minimum') ?? -1,
    valueMax: _optionalInt('Value maximum') ?? 0,
  );

  void _preset(DpProfile profile) {
    setState(() {
      _profile = profile;
      if (profile == DpProfile.custom) return;
      final modern = profile == DpProfile.modern;
      for (final entry in {
        'Power DP': modern ? '20' : '1',
        'Mode DP': modern ? '21' : '2',
        'Brightness DP': modern ? '22' : '3',
        'Temperature DP': modern ? '23' : '4',
        'Color DP': '',
        'Brightness minimum': modern ? '10' : '25',
        'Value maximum': modern ? '1000' : '255',
      }.entries) {
        _fields[entry.key]!.text = entry.value;
      }
    });
  }

  Future<void> _submit({bool test = false}) async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final config = _config();
      config.validate();
      if (test) {
        await ref.read(lightServiceProvider).read(config);
        if (mounted) {
          showMessage(
            context,
            'Light connected successfully over the local network.',
          );
        }
      } else {
        await ref
            .read(lightsProvider.notifier)
            .save(config, previousId: widget.config?.id);
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
      title: Text(widget.config == null ? 'Add Light' : 'Edit Light'),
    ),
    body: Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          for (final key in [
            'Name',
            'Device ID',
            'Private IP address',
            'Local key',
          ])
            DeviceField(
              controller: _fields[key]!,
              label: key,
              secret: key == 'Local key',
              enabled: !_busy,
            ),
          DropdownButtonFormField<double>(
            initialValue: _version,
            decoration: const InputDecoration(labelText: 'Protocol version'),
            items: [3.1, 3.3, 3.4, 3.5]
                .map(
                  (version) =>
                      DropdownMenuItem(value: version, child: Text('$version')),
                )
                .toList(),
            onChanged: _busy
                ? null
                : (value) => setState(() {
                    _version = value!;
                  }),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<DpProfile>(
            initialValue: _profile,
            decoration: const InputDecoration(labelText: 'DP layout'),
            items: const [
              DropdownMenuItem(
                value: DpProfile.modern,
                child: Text('Modern (20-24)'),
              ),
              DropdownMenuItem(
                value: DpProfile.legacy,
                child: Text('Legacy (1-5)'),
              ),
              DropdownMenuItem(value: DpProfile.custom, child: Text('Custom')),
            ],
            onChanged: _busy ? null : (value) => _preset(value!),
          ),
          const SizedBox(height: 16),
          ExpansionTile(
            title: const Text('Data Points'),
            children: [
              for (final key in [
                'Power DP',
                'Mode DP',
                'Brightness DP',
                'Temperature DP',
                'Color DP',
                'Brightness minimum',
                'Value maximum',
              ])
                DeviceField(
                  controller: _fields[key]!,
                  label: key,
                  numeric: true,
                  required:
                      key == 'Power DP' ||
                      key == 'Brightness minimum' ||
                      key == 'Value maximum',
                  enabled: !_busy,
                ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _submit(test: true),
            icon: const Icon(Icons.lan_outlined),
            label: const Text('Test connection'),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _submit,
            icon: const Icon(Icons.save_outlined),
            label: Text(_busy ? 'Please wait...' : 'Save Light'),
          ),
        ],
      ),
    ),
  );
}
