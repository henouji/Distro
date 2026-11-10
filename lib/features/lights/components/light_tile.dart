import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/components/feedback.dart';
import '../../../core/local_network.dart';
import '../light.dart';
import '../light_provider.dart';
import '../lights_controller.dart';
import 'light_editor.dart';

class LightTile extends ConsumerStatefulWidget {
  const LightTile({super.key, required this.config});
  final LightConfig config;
  @override
  ConsumerState<LightTile> createState() => _LightTileState();
}

class _LightTileState extends ConsumerState<LightTile> {
  bool _busy = false;
  double? _brightness, _temperature;

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
            content: SizedBox(
              width: 280,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 48,
                    width: double.infinity,
                    child: ColoredBox(color: color),
                  ),
                  const SizedBox(height: 16),
                  const Text('Hue'),
                  Slider(
                    value: hue,
                    max: 360,
                    onChanged: (next) => update(() {
                      hue = next;
                    }),
                  ),
                  const Text('Saturation'),
                  Slider(
                    value: saturation,
                    onChanged: (next) => update(() {
                      saturation = next;
                    }),
                  ),
                  const Text('Brightness'),
                  Slider(
                    value: value,
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
    return Card(
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
              const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [Text('Warm'), Text('Cool')],
              ),
            ],
            if (light?.hasColor ?? false)
              IconButton(
                onPressed: slidersEnabled ? _color : null,
                tooltip: 'Choose light color',
                icon: const Icon(Icons.palette_outlined),
              ),
            if (_busy) const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
