import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/components/feedback.dart';
import '../../../../core/local_network.dart';
import '../../../cameras/camera_controller.dart';
import '../../../cameras/components/camera_editor.dart';
import '../../../cameras/components/camera_view.dart';
import '../../../lights/components/light_editor.dart';
import '../../../lights/lights_controller.dart';
import '../../settings_controller.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String? _testing;
  Future<void> _run(
    String id,
    Future<void> Function() action, {
    bool success = true,
  }) async {
    setState(() {
      _testing = id;
    });
    try {
      await action();
      if (mounted && success) {
        showMessage(context, 'Local connection successful.');
      }
    } catch (error) {
      if (mounted) showMessage(context, friendlyError(error));
    } finally {
      if (mounted) {
        setState(() {
          _testing = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Appearance', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(
                value: ThemeMode.system,
                icon: Icon(Icons.brightness_auto),
                label: Text('System'),
              ),
              ButtonSegment(
                value: ThemeMode.light,
                icon: Icon(Icons.light_mode_outlined),
                label: Text('Light'),
              ),
              ButtonSegment(
                value: ThemeMode.dark,
                icon: Icon(Icons.dark_mode_outlined),
                label: Text('Dark'),
              ),
            ],
            selected: {settings.themeMode},
            onSelectionChanged: (modes) => _run(
              'theme',
              () => ref.read(settingsProvider.notifier).setTheme(modes.single),
              success: false,
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Live Camera Previews'),
            value: settings.livePreviews,
            onChanged: (enabled) => _run(
              'previews',
              () => ref.read(settingsProvider.notifier).setPreviews(enabled),
              success: false,
            ),
          ),
          const Divider(height: 32),
          _heading(
            'Lights',
            () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const LightEditor()),
            ),
          ),
          ref
              .watch(lightsProvider)
              .when(
                loading: () => const LinearProgressIndicator(),
                error: (error, stack) => RetryMessage(
                  error: error,
                  onRetry: () => ref.invalidate(lightsProvider),
                ),
                data: (lights) => Column(
                  children: [
                    for (final light in lights)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(light.name),
                        subtitle: Text(light.host),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => LightEditor(config: light),
                          ),
                        ),
                        trailing: IconButton(
                          tooltip: 'Test connection: ${light.name}',
                          onPressed: _testing != null
                              ? null
                              : () => _run(light.id, () async {
                                  await ref
                                      .read(lightServiceProvider)
                                      .read(light);
                                  ref.invalidate(lightStatusProvider(light));
                                }),
                          icon: _testing == light.id
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.lan_outlined),
                        ),
                      ),
                  ],
                ),
              ),
          const Divider(height: 32),
          _heading(
            'Cameras',
            () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const CameraEditor()),
            ),
          ),
          ref
              .watch(camerasProvider)
              .when(
                loading: () => const LinearProgressIndicator(),
                error: (error, stack) => RetryMessage(
                  error: error,
                  onRetry: () => ref.invalidate(camerasProvider),
                ),
                data: (cameras) => Column(
                  children: [
                    for (final camera in cameras)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(camera.name),
                        subtitle: Text(camera.host),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => CameraEditor(camera: camera),
                          ),
                        ),
                        trailing: IconButton(
                          tooltip: 'Test connection: ${camera.name}',
                          icon: const Icon(Icons.videocam_outlined),
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  CameraView(camera: camera, testing: true),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Widget _heading(String title, VoidCallback add) => Row(
    children: [
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      ),
      IconButton(
        tooltip: 'Add ${title == 'Lights' ? 'light' : 'camera'}',
        onPressed: add,
        icon: const Icon(Icons.add),
      ),
    ],
  );
}
