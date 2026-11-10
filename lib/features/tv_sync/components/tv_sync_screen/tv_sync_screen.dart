import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/components/feedback.dart';
import '../../../../core/components/glass.dart';
import '../../../lights/lights_controller.dart';
import '../../remote/tv_remote_host.dart';
import '../../tv_platform.dart';
import '../../tv_sync_controller.dart';
import '../../tv_sync_engine.dart';
import '../tv_remote_screen/tv_remote_screen.dart';

/// TV tab: the sync screen on a TV, the remote control everywhere else.
class TvScreen extends ConsumerWidget {
  const TvScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      ref.watch(deviceIsTvProvider).when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => const TvRemoteScreen(),
        data: (isTv) => isTv ? const TvSyncScreen() : const TvRemoteScreen(),
      );
}

/// Lets tablets on the home network pair with and control this TV.
class _TabletControlPanel extends ConsumerWidget {
  const _TabletControlPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = ref.watch(tvRemoteHostProvider);
    final controller = ref.read(tvRemoteHostProvider.notifier);
    final theme = Theme.of(context);
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // A full-width tile keeps the switch in the D-pad's vertical path.
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              title: const Text('Tablet control'),
              subtitle: const Text(
                'Let a paired tablet see what is playing, open apps and turn '
                'Light Sync on or off. Keep HomeHub open on the TV.',
              ),
              value: host.enabled,
              onChanged: controller.setEnabled,
            ),
          ),
          if (host.error != null)
            Text(host.error!, style: TextStyle(color: theme.colorScheme.error)),
          if (host.running) ...[
            const SizedBox(height: 8),
            Text(
              'On the tablet open HomeHub → TV and enter:',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 32,
              runSpacing: 8,
              children: [
                _Field('TV address', host.address ?? 'Unknown'),
                _Field('Pairing code', host.pairingCode ?? '------'),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    host.paired == 0
                        ? 'No tablets paired yet.'
                        : '${host.paired} tablet(s) paired.',
                  ),
                ),
                if (host.paired > 0)
                  TextButton(
                    onPressed: controller.forgetTablets,
                    child: const Text('Forget paired tablets'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelMedium),
      Text(
        value,
        style: Theme.of(
          context,
        ).textTheme.headlineMedium?.copyWith(letterSpacing: 2),
      ),
    ],
  );
}

class TvSyncScreen extends ConsumerWidget {
  const TvSyncScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(tvSyncProvider);
    final controller = ref.read(tvSyncProvider.notifier);
    final idle = sync.status == TvSyncStatus.idle;
    final settings = sync.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('TV Sync')),
      body: ref
          .watch(lightsProvider)
          .when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stack) => Center(
              child: RetryMessage(
                error: error,
                onRetry: () => ref.invalidate(lightsProvider),
              ),
            ),
            data: (lights) {
              final selected = lights
                  .where((light) => light.id == sync.lightId)
                  .firstOrNull;
              SyncMode? mode;
              try {
                if (selected != null) mode = syncModeFor(selected);
              } catch (_) {}
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  GlassPanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            _Swatch(frame: sync.preview, mode: sync.mode),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Text(switch (sync.status) {
                                TvSyncStatus.idle =>
                                  'Run HomeHub on your Android / Google TV '
                                      'and the light will follow what is on '
                                      'screen.',
                                TvSyncStatus.starting =>
                                  'Connecting to the light and asking to '
                                      'capture the screen...',
                                TvSyncStatus.running =>
                                  'Syncing. Press Home and play something; '
                                      'the light keeps following in the '
                                      'background.',
                              }),
                            ),
                          ],
                        ),
                        if (sync.error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            sync.error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          initialValue: selected?.id,
                          decoration: const InputDecoration(
                            labelText: 'Light',
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            for (final light in lights)
                              DropdownMenuItem(
                                value: light.id,
                                child: Text(light.name),
                              ),
                          ],
                          onChanged: idle
                              ? (id) {
                                  if (id != null) controller.selectLight(id);
                                }
                              : null,
                        ),
                        if (lights.isEmpty)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text('Add a light first in Lights.'),
                          ),
                        if (selected != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(switch (mode) {
                              SyncMode.color =>
                                'Color mode: matches the picture color and '
                                    'brightness.',
                              SyncMode.white =>
                                'White mode: this bulb has no color data '
                                    'point, so it follows brightness and '
                                    'warm/cool tone.',
                              null => 'This light cannot be synced.',
                            }),
                          ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          autofocus: true,
                          onPressed: switch (sync.status) {
                            TvSyncStatus.starting => null,
                            TvSyncStatus.running => controller.stop,
                            TvSyncStatus.idle =>
                              mode == null ? null : controller.start,
                          },
                          icon: Icon(
                            idle ? Icons.play_arrow : Icons.stop_rounded,
                          ),
                          label: Text(idle ? 'Start TV Sync' : 'Stop TV Sync'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  GlassPanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _slider(
                          context,
                          'Darkest scene brightness',
                          settings.minBrightness,
                          (value) => controller.updateSettings(
                            settings.copyWith(minBrightness: value),
                          ),
                        ),
                        _slider(
                          context,
                          'Brightest scene brightness',
                          settings.maxBrightness,
                          (value) => controller.updateSettings(
                            settings.copyWith(maxBrightness: value),
                          ),
                        ),
                        _slider(
                          context,
                          'Breathing smoothness',
                          settings.smoothing * 100,
                          (value) => controller.updateSettings(
                            settings.copyWith(smoothing: value / 100),
                          ),
                          start: 'Snappy',
                          end: 'Smooth',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  const _TabletControlPanel(),
                  const SizedBox(height: 16),
                  // Focusable so a TV remote can scroll the note into view.
                  Focus(
                    child: Builder(
                      builder: (context) => DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Focus.of(context).hasFocus
                                ? Theme.of(context).colorScheme.primary
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            'Protected apps (Netflix, Disney+ and others) '
                            'block screen capture, so the light may stay dim '
                            'during them. Sync keeps the bulb\'s only local '
                            'connection open; other Tuya apps cannot control '
                            'it until you stop sync.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
    );
  }

  Widget _slider(
    BuildContext context,
    String label,
    double value,
    ValueChanged<double> onChanged, {
    String? start,
    String? end,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        start == null ? '$label: ${value.round()}%' : label,
        style: Theme.of(context).textTheme.titleSmall,
      ),
      Row(
        children: [
          if (start != null) Text(start),
          Expanded(
            child: Slider(
              value: value.clamp(0, 100).toDouble(),
              max: 100,
              divisions: 20,
              label: '${value.round()}',
              semanticFormatterCallback: (value) => '$label ${value.round()}',
              onChanged: onChanged,
            ),
          ),
          if (end != null) Text(end),
        ],
      ),
    ],
  );
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.frame, required this.mode});
  final LightFrame? frame;
  final SyncMode? mode;

  @override
  Widget build(BuildContext context) {
    final frame = this.frame;
    var color = Colors.black26;
    if (frame != null) {
      if (mode == SyncMode.color) {
        final (r, g, b) = frame.rgb;
        color = Color.fromARGB(255, r, g, b);
      } else {
        const warm = Color(0xFFFFC27A), cool = Color(0xFFE3EEFF);
        color = Color.lerp(
          Colors.black,
          Color.lerp(warm, cool, frame.temperature / 100)!,
          (frame.brightness / 100).clamp(.08, 1).toDouble(),
        )!;
      }
    }
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white54),
      ),
      child: Icon(
        Icons.tv,
        color: frame == null ? null : Colors.white70,
        semanticLabel: 'Light preview',
      ),
    );
  }
}
