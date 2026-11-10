import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/components/feedback.dart';
import '../../../core/local_network.dart';
import '../light.dart';
import '../light_schedule.dart';
import '../lighting_runtime.dart';
import '../lights_controller.dart';
import 'light_schedule_editor.dart';

final lightingRuntimeProvider = Provider((ref) => LightingRuntime());

class LightingScheduleScreen extends ConsumerStatefulWidget {
  const LightingScheduleScreen({super.key});

  @override
  ConsumerState<LightingScheduleScreen> createState() =>
      _LightingScheduleScreenState();
}

class _LightingScheduleScreenState
    extends ConsumerState<LightingScheduleScreen> {
  Timer? _timer;
  bool _running = false, _busy = false, _polling = false;
  bool _batteryOptimized = false;
  String? _quickLightId, _selectedLightId;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _message(Object error) => error is PlatformException
      ? error.message ?? 'Scheduled lighting is unavailable.'
      : friendlyError(error);

  Future<void> _refresh() async {
    if (_polling) return;
    _polling = true;
    try {
      final status = await ref.read(lightingRuntimeProvider).status();
      if (mounted) {
        setState(() {
          _running = status['running'] == true;
          _quickLightId = status['quickLightId'] as String?;
          _batteryOptimized = status['batteryOptimized'] == true;
          _error = status['error'] as String?;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      _polling = false;
    }
  }

  Future<void> _command(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await _refresh();
    } catch (error) {
      if (mounted) showMessage(context, _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(LightConfig config) async {
    final schedule = await showDialog<LightSchedule>(
      context: context,
      builder: (_) => LightScheduleEditor(initial: config.schedule),
    );
    if (schedule == null || !mounted) return;
    await _save(config, schedule);
  }

  Future<void> _save(LightConfig config, LightSchedule? schedule) => _command(
    () => ref
        .read(lightsProvider.notifier)
        .save(
          LightConfig.fromJson({
            ...config.toJson(),
            'schedule': schedule?.toJson(),
          }),
        ),
  );

  @override
  Widget build(BuildContext context) {
    final lights = ref.watch(lightsProvider);
    final canStart =
        lights.asData?.value.any((light) => light.schedule?.enabled == true) ??
        false;
    return Scaffold(
      appBar: AppBar(title: const Text('Dynamic lighting')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            _running ? 'Schedules are running' : 'Schedules are stopped',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Start schedules on one HomeHub device connected to your lights. '
            'Updates run about every 30 seconds, including with the screen off. '
            'Keep this device powered and on home Wi-Fi. '
            'Manual changes are overwritten at the next update. '
            'Stopping schedules leaves lights at their current settings.',
          ),
          if (_batteryOptimized) ...[
            const SizedBox(height: 12),
            const Text(
              'Android battery optimization can interrupt Wi-Fi while the screen '
              'is off. Allow unrestricted battery use for HomeHub for reliable '
              'background lighting. This uses additional battery.',
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () =>
                    _command(ref.read(lightingRuntimeProvider).batterySettings),
                child: const Text('Battery settings'),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            children: [
              FilledButton.icon(
                onPressed: _busy || _running || !canStart
                    ? null
                    : () => _command(ref.read(lightingRuntimeProvider).start),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start schedules'),
              ),
              OutlinedButton.icon(
                onPressed: _busy || !_running
                    ? null
                    : () => _command(ref.read(lightingRuntimeProvider).stop),
                icon: const Icon(Icons.stop),
                label: const Text('Stop schedules'),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 16),
          ...lights.when(
            loading: () => [const Center(child: CircularProgressIndicator())],
            error: (error, stack) => [
              RetryMessage(
                error: error,
                onRetry: () => ref.invalidate(lightsProvider),
              ),
            ],
            data: (items) => [
              if (items.isNotEmpty || _quickLightId != null) ...[
                Text(
                  'Notification light controls',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Text(
                  'Use on/off, brightness, White (warm/cool) and Color '
                  '(cycles presets) directly in the notification, without '
                  'expanding it. Unsupported controls are hidden. Hide these controls '
                  'before using TV Sync. Lock-screen visibility follows Android settings.',
                ),
                const SizedBox(height: 8),
                if (items.isNotEmpty)
                  DropdownButtonFormField<String>(
                    key: ValueKey(_selectedLightId ?? _quickLightId),
                    initialValue:
                        items.any(
                          (light) =>
                              light.id == (_selectedLightId ?? _quickLightId),
                        )
                        ? _selectedLightId ?? _quickLightId
                        : null,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Notification bulb',
                    ),
                    items: [
                      for (final light in items)
                        DropdownMenuItem(
                          value: light.id,
                          child: Text(light.name),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (id) => setState(() => _selectedLightId = id),
                  ),
                Wrap(
                  spacing: 12,
                  children: [
                    TextButton(
                      onPressed:
                          _busy ||
                              !items.any(
                                (light) =>
                                    light.id ==
                                    (_selectedLightId ?? _quickLightId),
                              )
                          ? null
                          : () => _command(
                              () => ref
                                  .read(lightingRuntimeProvider)
                                  .pin((_selectedLightId ?? _quickLightId)!),
                            ),
                      child: const Text('Show notification controls'),
                    ),
                    TextButton(
                      onPressed: _busy || _quickLightId == null
                          ? null
                          : () => _command(
                              ref.read(lightingRuntimeProvider).hide,
                            ),
                      child: const Text('Hide notification controls'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              if (items.isEmpty)
                const Text('Add a light before creating a schedule.'),
              for (final config in items)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          config.name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          config.schedule == null
                              ? 'No timeline'
                              : config.schedule!.enabled
                              ? 'Enabled'
                              : 'Disabled',
                        ),
                        if (config.schedule != null) ...[
                          Text(
                            config.schedule!.days
                                .map((day) => lightingWeekdays[day - 1])
                                .join(', '),
                          ),
                          for (final point in config.schedule!.points)
                            Text(
                              '${lightingTime(context, point.minute)}: '
                              '${point.brightness.round()}% brightness, '
                              '${point.temperature.round()}% temperature',
                            ),
                        ],
                        if (config.brightnessDp == null ||
                            config.temperatureDp == null)
                          const Text(
                            'Configure brightness and temperature DPs to schedule this light.',
                          )
                        else
                          Wrap(
                            spacing: 12,
                            children: [
                              TextButton(
                                onPressed: _busy ? null : () => _edit(config),
                                child: Text(
                                  config.schedule == null
                                      ? 'Create timeline'
                                      : 'Edit timeline',
                                ),
                              ),
                              if (config.schedule != null)
                                TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _save(config, null),
                                  child: const Text('Remove schedule'),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
