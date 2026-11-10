import 'package:flutter/material.dart';

import '../light.dart';
import 'color_wheel.dart';

class LightPresetEditor extends StatefulWidget {
  const LightPresetEditor({
    super.key,
    required this.config,
    required this.slot,
    this.initial,
  });

  final LightConfig config;
  final int slot;
  final LightPreset? initial;

  @override
  State<LightPresetEditor> createState() => _LightPresetEditorState();
}

class _LightPresetEditorState extends State<LightPresetEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late bool _colorMode;
  late double _brightness, _temperature;
  late HSVColor _color;

  @override
  void initState() {
    super.initState();
    final preset = widget.initial;
    _name = TextEditingController(
      text: preset?.name ?? 'Preset ${widget.slot + 1}',
    );
    _colorMode = preset?.hue != null && widget.config.colorDp != null;
    _brightness = preset?.brightness ?? 100;
    _temperature = preset?.temperature ?? 50;
    _color = HSVColor.fromAHSV(1, preset?.hue ?? 0, preset?.saturation ?? 1, 1);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Edit preset ${widget.slot + 1}'),
    scrollable: true,
    content: SizedBox(
      width: 280,
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Preset name'),
              maxLength: 24,
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter a preset name.'
                  : null,
            ),
            if (widget.config.colorDp != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Color mode'),
                value: _colorMode,
                onChanged: (value) => setState(() => _colorMode = value),
              ),
            if (_colorMode)
              ColorWheel(
                color: _color,
                onChanged: (value) => setState(() => _color = value),
              ),
            if (_colorMode || widget.config.brightnessDp != null) ...[
              Text('Brightness ${_brightness.round()}%'),
              Slider(
                value: _brightness,
                max: 100,
                semanticFormatterCallback: (value) =>
                    '${value.round()} percent brightness',
                onChanged: (value) => setState(() => _brightness = value),
              ),
            ],
            if (!_colorMode && widget.config.temperatureDp != null) ...[
              Text('Color Temperature ${_temperature.round()}%'),
              Slider(
                value: _temperature,
                max: 100,
                semanticFormatterCallback: (value) =>
                    '${value.round()} percent from warm to cool',
                onChanged: (value) => setState(() => _temperature = value),
              ),
            ],
            const Text('Saving a preset does not change the light.'),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (!_form.currentState!.validate()) return;
          Navigator.pop(
            context,
            LightPreset(
              name: _name.text.trim(),
              brightness: _brightness,
              temperature: _temperature,
              hue: _colorMode ? _color.hue : null,
              saturation: _color.saturation,
            ),
          );
        },
        child: const Text('Save preset'),
      ),
    ],
  );
}
