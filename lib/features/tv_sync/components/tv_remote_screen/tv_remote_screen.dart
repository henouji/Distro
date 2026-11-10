import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/components/feedback.dart';
import '../../../../core/components/glass.dart';
import '../../../../core/local_network.dart';
import '../../../lights/lights_controller.dart';
import '../../remote/tv_remote_client.dart';
import '../../remote/tv_remote_protocol.dart';
import '../../tv_platform.dart';
import '../../tv_sync_controller.dart';
import '../../tv_sync_engine.dart';

/// Tablet/phone screen that controls HomeHub running on the TV.
class TvRemoteScreen extends ConsumerWidget {
  const TvRemoteScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paired = ref.watch(pairedTvProvider);
    final tv = paired.value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('TV'),
        actions: [
          if (tv != null) ...[
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: () {
                ref.invalidate(tvRemoteStateProvider);
                ref.invalidate(tvAppsProvider);
              },
            ),
            IconButton(
              tooltip: 'Unpair TV',
              icon: const Icon(Icons.link_off),
              onPressed: () async {
                if (await confirmDelete(context, 'the TV pairing')) {
                  await ref.read(pairedTvProvider.notifier).forget();
                }
              },
            ),
          ],
        ],
      ),
      body: paired.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: RetryMessage(
            error: error,
            onRetry: () => ref.invalidate(pairedTvProvider),
          ),
        ),
        data: (tv) => tv == null ? const _PairForm() : const _RemotePanel(),
      ),
    );
  }
}

class _PairForm extends ConsumerStatefulWidget {
  const _PairForm();
  @override
  ConsumerState<_PairForm> createState() => _PairFormState();
}

class _PairFormState extends ConsumerState<_PairForm> {
  final _host = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _host.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(pairedTvProvider.notifier).pair(_host.text, _code.text);
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      GlassPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Pair with your TV',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'On the TV, open HomeHub → TV Sync and turn on "Tablet control". '
              'Enter the address and 6-digit code it shows.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _host,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'TV IP address',
                hintText: '192.168.68.111',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _code,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              maxLength: 6,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Pairing code',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _pair(),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            FilledButton.icon(
              onPressed: _busy ? null : _pair,
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.link),
              label: const Text('Pair'),
            ),
          ],
        ),
      ),
    ],
  );
}

class _RemotePanel extends ConsumerStatefulWidget {
  const _RemotePanel();
  @override
  ConsumerState<_RemotePanel> createState() => _RemotePanelState();
}

class _RemotePanelState extends ConsumerState<_RemotePanel> {
  String? _busy;
  SyncSettings? _draft;

  Future<void> _act(
    String id,
    Future<void> Function(TvRemoteApi api) action,
  ) async {
    final api = ref.read(tvRemoteApiProvider);
    if (api == null || _busy != null) return;
    setState(() => _busy = id);
    try {
      await action(api);
    } catch (error) {
      if (mounted) showMessage(context, friendlyError(error));
    } finally {
      if (mounted) {
        setState(() => _busy = null);
        ref.invalidate(tvRemoteStateProvider);
      }
    }
  }

  Future<void> _sendLights() => _act('lights', (api) async {
    final lights = await ref.read(lightsProvider.future);
    if (lights.isEmpty) {
      throw const HomeHubException('Add a light on this tablet first.');
    }
    await api.sendLights(lights);
    if (mounted) {
      showMessage(context, 'Sent ${lights.length} light(s) to the TV.');
    }
  });

  @override
  Widget build(BuildContext context) {
    final remote = ref.watch(tvRemoteStateProvider);
    final snapshot = remote.value;
    if (snapshot == null) {
      return remote.hasError
          ? Center(
              child: RetryMessage(
                error: remote.error!,
                onRetry: () => ref.invalidate(tvRemoteStateProvider),
              ),
            )
          : const Center(child: CircularProgressIndicator());
    }
    final apps = ref.watch(tvAppsProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final sync = _syncPanel(context, snapshot);
        final now = _nowPlaying(context, snapshot, apps.value);
        final appGrid = _appsPanel(context, snapshot, apps);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (remote.hasError)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  friendlyError(remote.error!),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: now),
                  const SizedBox(width: 16),
                  Expanded(child: sync),
                ],
              )
            else ...[
              now,
              const SizedBox(height: 16),
              sync,
            ],
            const SizedBox(height: 16),
            appGrid,
          ],
        );
      },
    );
  }

  Widget _nowPlaying(
    BuildContext context,
    TvRemoteSnapshot snapshot,
    List<TvApp>? apps,
  ) {
    final app = snapshot.app;
    final icon = apps
        ?.where((item) => item.package == app.package)
        .firstOrNull
        ?.icon;
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Now on TV', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Row(
            children: [
              SizedBox.square(
                dimension: 56,
                child: icon != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(icon, gaplessPlayback: true),
                      )
                    : const Icon(Icons.tv, size: 40),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  app.label ??
                      (app.usageAccess
                          ? 'Nothing detected yet'
                          : 'Unknown – allow "Usage access" for HomeHub on '
                                'the TV'),
                  style: app.label == null
                      ? null
                      : Theme.of(context).textTheme.headlineSmall,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _syncPanel(BuildContext context, TvRemoteSnapshot snapshot) {
    final running = snapshot.status == TvSyncStatus.running;
    final starting =
        snapshot.status == TvSyncStatus.starting || _busy == 'sync';
    final settings = _draft ?? snapshot.settings;
    final selected = snapshot.lights
        .where((light) => light.id == snapshot.lightId)
        .firstOrNull;
    final preview = snapshot.preview;
    void saveSettings(SyncSettings next) => _act('settings', (api) async {
      try {
        await api.updateSettings(next);
      } finally {
        if (mounted) setState(() => _draft = null);
      }
    });

    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: preview == null
                      ? Colors.black26
                      : Color.fromARGB(255, preview.$1, preview.$2, preview.$3),
                  border: Border.all(color: Colors.white54),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Light Sync',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (starting)
                const Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              Switch(
                value: running,
                onChanged: starting || (!running && selected?.mode == null)
                    ? null
                    : (on) => _act(
                        'sync',
                        (api) => on
                            ? api.startSync(lightId: snapshot.lightId)
                            : api.stopSync(),
                      ),
              ),
            ],
          ),
          if (snapshot.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                snapshot.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 16),
          if (snapshot.lights.isEmpty)
            const Text(
              'No lights are set up on the TV yet. Send the lights from this '
              'tablet to the TV to sync them.',
            )
          else
            DropdownButtonFormField<String>(
              key: ValueKey(snapshot.lightId),
              initialValue: selected?.id,
              decoration: const InputDecoration(
                labelText: 'Light on the TV',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final light in snapshot.lights)
                  DropdownMenuItem(value: light.id, child: Text(light.name)),
              ],
              onChanged: running || _busy != null
                  ? null
                  : (id) {
                      if (id != null) {
                        _act('light', (api) => api.selectLight(id));
                      }
                    },
            ),
          if (selected != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(switch (selected.mode) {
                SyncMode.color => 'Follows the picture color and brightness.',
                SyncMode.white =>
                  'White bulb: follows brightness and warm/cool tone.',
                null => 'This light cannot be synced.',
              }),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy == null ? _sendLights : null,
              icon: const Icon(Icons.send_to_mobile_outlined),
              label: const Text('Send my lights to the TV'),
            ),
          ),
          const SizedBox(height: 8),
          _slider(
            'Darkest scene brightness',
            settings.minBrightness,
            (value) => setState(
              () => _draft = settings.copyWith(minBrightness: value),
            ),
            (value) => saveSettings(settings.copyWith(minBrightness: value)),
          ),
          _slider(
            'Brightest scene brightness',
            settings.maxBrightness,
            (value) => setState(
              () => _draft = settings.copyWith(maxBrightness: value),
            ),
            (value) => saveSettings(settings.copyWith(maxBrightness: value)),
          ),
          _slider(
            'Breathing smoothness',
            settings.smoothing * 100,
            (value) => setState(
              () => _draft = settings.copyWith(smoothing: value / 100),
            ),
            (value) => saveSettings(settings.copyWith(smoothing: value / 100)),
          ),
        ],
      ),
    );
  }

  Widget _slider(
    String label,
    double value,
    ValueChanged<double> onChanged,
    ValueChanged<double> onChangeEnd,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('$label: ${value.round()}%'),
      Slider(
        value: value.clamp(0, 100).toDouble(),
        max: 100,
        divisions: 20,
        label: '${value.round()}',
        onChanged: _busy == null || _busy == 'settings' ? onChanged : null,
        onChangeEnd: onChangeEnd,
      ),
    ],
  );

  Widget _appsPanel(
    BuildContext context,
    TvRemoteSnapshot snapshot,
    AsyncValue<List<TvApp>> apps,
  ) => GlassPanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Apps on TV', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        apps.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, stack) => RetryMessage(
            error: error,
            onRetry: () => ref.invalidate(tvAppsProvider),
          ),
          data: (apps) => apps.isEmpty
              ? const Text('No apps reported by the TV.')
              : Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final app in apps)
                      _AppTile(
                        app: app,
                        current: app.package == snapshot.app.package,
                        busy: _busy == app.package,
                        onTap: _busy == null
                            ? () => _act(
                                app.package,
                                (api) => api.launch(app.package),
                              )
                            : null,
                      ),
                  ],
                ),
        ),
      ],
    ),
  );
}

class _AppTile extends StatelessWidget {
  const _AppTile({
    required this.app,
    required this.current,
    required this.busy,
    required this.onTap,
  });

  final TvApp app;
  final bool current, busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Open ${app.label} on the TV',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: 104,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: current ? scheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
          child: Column(
            children: [
              SizedBox.square(
                dimension: 56,
                child: busy
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : app.icon != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(app.icon!, gaplessPlayback: true),
                      )
                    : const Icon(Icons.apps, size: 40),
              ),
              const SizedBox(height: 6),
              Text(
                app.label,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
