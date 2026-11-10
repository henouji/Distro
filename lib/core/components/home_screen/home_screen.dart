import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/cameras/camera_controller.dart';
import '../../../features/cameras/components/camera_tile.dart';
import '../../../features/lights/components/light_tile.dart';
import '../../../features/lights/lights_controller.dart';
import '../feedback.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key, required this.onNavigate});
  final ValueChanged<int> onNavigate;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(
      title: const Text('HomeHub'),
      actions: const [
        Padding(
          padding: EdgeInsets.only(right: 20),
          child: Tooltip(
            message: 'Local network only',
            child: Icon(Icons.lan_outlined),
          ),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _heading(context, 'Lights', 1),
        ref
            .watch(lightsProvider)
            .when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stack) => RetryMessage(
                error: error,
                onRetry: () => ref.invalidate(lightsProvider),
              ),
              data: (lights) => lights.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text('No lights added.'),
                    )
                  : Column(
                      children: [
                        for (final config in lights.take(3))
                          LightTile(key: ValueKey(config.id), config: config),
                      ],
                    ),
            ),
        const SizedBox(height: 16),
        _heading(context, 'Cameras', 2),
        ref
            .watch(camerasProvider)
            .when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stack) => RetryMessage(
                error: error,
                onRetry: () => ref.invalidate(camerasProvider),
              ),
              data: (cameras) => cameras.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text('No cameras added.'),
                    )
                  : CameraGrid(cameras: cameras.take(2).toList()),
            ),
      ],
    ),
  );

  Widget _heading(BuildContext context, String title, int tab) => Row(
    children: [
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.titleLarge),
      ),
      IconButton(
        tooltip: 'View all $title',
        onPressed: () => onNavigate(tab),
        icon: const Icon(Icons.arrow_forward),
      ),
    ],
  );
}
