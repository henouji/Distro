import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/components/feedback.dart';
import '../../../core/components/glass.dart';
import '../../../core/local_network.dart';
import '../light.dart';
import '../light_provider.dart';
import '../lights_controller.dart';
import 'color_wheel.dart';
import 'light_editor.dart';
import 'light_preset_editor.dart';

class LightTile extends ConsumerStatefulWidget {
  const LightTile({super.key, required this.config});
  final LightConfig config;
  @override
  ConsumerState<LightTile> createState() => _LightTileState();
}

class _LightTileState extends ConsumerState<LightTile> {
  bool _busy = false;
  double? _brightness, _temperature;

  Future<void> _editPreset(int slot) async {
    final preset = await showDialog<LightPreset>(
      context: context,
      builder: (_) => LightPresetEditor(
        config: widget.config,
        slot: slot,
        initial: widget.config.presets[slot],
      ),
    );
    if (preset == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(lightsProvider.notifier)
          .savePreset(widget.config.id, slot, preset);
    } catch (error) {
      if (mounted) showMessage(context, friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _applyPreset(LightPreset preset, LightState light) => _command((
    provider,
  ) async {
    if (preset.hue != null && !light.hasColor) {
      throw const HomeHubException(
        'This color preset is not supported. Edit the preset or DP mapping.',
      );
    }
    if (preset.hue != null) {
      final color = HSVColor.fromAHSV(
        1,
        preset.hue!,
        preset.saturation,
        preset.brightness / 100,
      ).toColor();
      await provider.setColor(
        widget.config,
        (color.r * 255).round(),
        (color.g * 255).round(),
        (color.b * 255).round(),
      );
    } else {
      if (light.hasTemperature) {
        await provider.setTemperature(widget.config, preset.temperature);
      }
      if (light.hasBrightness) {
        await provider.setBrightness(widget.config, preset.brightness);
      }
    }
    await provider.setPower(widget.config, true);
  });

  Future<void> _command(Future<void> Function(LightProvider) action) async {
    setState(() {
      _busy = true;
    });
    try {
      await action(ref.read(lightServiceProvider));
    } catch (error) {
      if (mounted) showMessage(context, friendlyError(error));
    } finally {
      if (mounted) {
        ref.invalidate(lightStatusProvider(widget.config));
        setState(() {
          _busy = false;
          _brightness = null;
          _temperature = null;
        });
      }
    }
  }

  Future<void> _color() async {
    var hue = 0.0;
    var saturation = 1.0;
    var value = 1.0;
    final selected = await showDialog<Color>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final color = HSVColor.fromAHSV(1, hue, saturation, value).toColor();
          return AlertDialog(
            title: const Text('Light Color'),
            scrollable: true,
            content: SizedBox(
              width: 280,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ColorWheel(
                    color: HSVColor.fromAHSV(1, hue, saturation, value),
                    onChanged: (next) => update(() {
                      hue = next.hue;
                      saturation = next.saturation;
                    }),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 48,
                    width: double.infinity,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final preset in [
                        (0.0, 'Red'),
                        (45.0, 'Amber'),
                        (130.0, 'Green'),
                        (210.0, 'Blue'),
                      ])
                        IconButton(
                          tooltip: preset.$2,
                          onPressed: () => update(() {
                            hue = preset.$1;
                            saturation = 1;
                          }),
                          icon: Icon(
                            Icons.circle,
                            color: HSVColor.fromAHSV(
                              1,
                              preset.$1,
                              1,
                              1,
                            ).toColor(),
                          ),
                        ),
                    ],
                  ),
                  const Text('Hue'),
                  Slider(
                    value: hue,
                    max: 360,
                    label: '${hue.round()} degrees',
                    semanticFormatterCallback: (value) =>
                        '${value.round()} degrees hue',
                    onChanged: (next) => update(() {
                      hue = next;
                    }),
                  ),
                  const Text('Saturation'),
                  Slider(
                    value: saturation,
                    label: '${(saturation * 100).round()}%',
                    semanticFormatterCallback: (value) =>
                        '${(value * 100).round()} percent saturation',
                    onChanged: (next) => update(() {
                      saturation = next;
                    }),
                  ),
                  const Text('Brightness'),
                  Slider(
                    value: value,
                    label: '${(value * 100).round()}%',
                    semanticFormatterCallback: (value) =>
                        '${(value * 100).round()} percent brightness',
                    onChanged: (next) => update(() {
                      value = next;
                    }),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, color),
                child: const Text('Apply'),
              ),
            ],
          );
        },
      ),
    );
    if (selected != null && mounted) {
      await _command(
        (provider) => provider.setColor(
          widget.config,
          (selected.r * 255).round(),
          (selected.g * 255).round(),
          (selected.b * 255).round(),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(lightStatusProvider(widget.config));
    final light = status.asData?.value;
    final online = light?.online ?? false;
    final enabled = online && !_busy;
    final slidersEnabled = enabled && light!.on;
    return GlassPanel(
      padding: EdgeInsets.zero,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.lightbulb_outline,
                  color: online && light!.on
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.config.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        status.isLoading
                            ? 'Connecting...'
                            : online
                            ? 'Online'
                            : 'Offline',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: light?.on ?? false,
                  onChanged: enabled
                      ? (on) => _command(
                          (provider) => provider.setPower(widget.config, on),
                        )
                      : null,
                ),
                PopupMenuButton<String>(
                  tooltip: 'Light options',
                  onSelected: (action) async {
                    if (action == 'edit') {
                      await Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => LightEditor(config: widget.config),
                        ),
                      );
                    } else if (await confirmDelete(
                      context,
                      widget.config.name,
                    )) {
                      try {
                        await ref
                            .read(lightsProvider.notifier)
                            .delete(widget.config.id);
                      } catch (error) {
                        if (context.mounted) {
                          showMessage(context, friendlyError(error));
                        }
                      }
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ],
            ),
            if (status.hasError) ...[
              const SizedBox(height: 12),
              Text(friendlyError(status.error!)),
              TextButton.icon(
                onPressed: () =>
                    ref.invalidate(lightStatusProvider(widget.config)),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
            if (light?.hasBrightness ?? false) ...[
              const SizedBox(height: 12),
              Text('Brightness ${(_brightness ?? light!.brightness).round()}%'),
              Slider(
                semanticFormatterCallback: (value) =>
                    '${value.round()} percent brightness',
                label: '${(_brightness ?? light!.brightness).round()}%',
                value: _brightness ?? light!.brightness,
                max: 100,
                onChanged: slidersEnabled
                    ? (value) => setState(() {
                        _brightness = value;
                      })
                    : null,
                onChangeEnd: slidersEnabled
                    ? (value) => _command(
                        (provider) =>
                            provider.setBrightness(widget.config, value),
                      )
                    : null,
              ),
            ],
            if (light?.hasTemperature ?? false) ...[
              Text(
                'Color Temperature ${(_temperature ?? light!.temperature).round()}%',
              ),
              Slider(
                semanticFormatterCallback: (value) =>
                    '${value.round()} percent from warm to cool',
                label: '${(_temperature ?? light!.temperature).round()}%',
                value: _temperature ?? light!.temperature,
                max: 100,
                onChanged: slidersEnabled
                    ? (value) => setState(() {
                        _temperature = value;
                      })
                    : null,
                onChangeEnd: slidersEnabled
                    ? (value) => _command(
                        (provider) =>
                            provider.setTemperature(widget.config, value),
                      )
                    : null,
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Warm',
                    style: TextStyle(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? const Color(0xFFEDB86A)
                          : const Color(0xFF8C5015),
                    ),
                  ),
                  Text(
                    'Cool',
                    style: TextStyle(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? const Color(0xFFA4C9FF)
                          : const Color(0xFF31669B),
                    ),
                  ),
                ],
              ),
            ],
            if (light?.hasColor ?? false)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: OutlinedButton.icon(
                  onPressed: slidersEnabled ? _color : null,
                  icon: const Icon(Icons.palette_outlined),
                  label: const Text('Choose light color'),
                ),
              ),
            const SizedBox(height: 16),
            const Text('Presets'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var slot = 0; slot < 3; slot++)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 160),
                        child: OutlinedButton(
                          onPressed: _busy
                              ? null
                              : widget.config.presets[slot] == null
                              ? () => _editPreset(slot)
                              : enabled
                              ? () => _applyPreset(
                                  widget.config.presets[slot]!,
                                  light!,
                                )
                              : null,
                          child: Text(
                            widget.config.presets[slot]?.name ??
                                'Set preset ${slot + 1}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      if (widget.config.presets[slot] != null)
                        IconButton(
                          tooltip: 'Edit preset ${slot + 1}',
                          onPressed: _busy ? null : () => _editPreset(slot),
                          icon: const Icon(Icons.edit_outlined, size: 20),
                        ),
                    ],
                  ),
              ],
            ),
            if (_busy) const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
