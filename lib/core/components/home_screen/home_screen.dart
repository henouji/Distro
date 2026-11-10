import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/cameras/camera_controller.dart';
import '../../../features/cameras/components/camera_tile.dart';
import '../../../features/lights/components/light_tile.dart';
import '../../../features/lights/lights_controller.dart';
import '../feedback.dart';
import '../glass.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key, required this.onNavigate});
  final ValueChanged<int> onNavigate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lights = ref.watch(lightsProvider);
    final cameras = ref.watch(camerasProvider);
    final lighting = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, 'Lighting', 'Set the atmosphere', 1),
        lights.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) => RetryMessage(
            error: error,
            onRetry: () => ref.invalidate(lightsProvider),
          ),
          data: (items) => items.isEmpty
              ? _empty('No lights added.', Icons.lightbulb_outline, 1)
              : Column(
                  children: [
                    for (final config in items.take(3))
                      LightTile(key: ValueKey(config.id), config: config),
                  ],
                ),
        ),
      ],
    );
    final surveillance = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, 'Cameras', 'A little peace of mind', 2),
        cameras.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) => RetryMessage(
            error: error,
            onRetry: () => ref.invalidate(camerasProvider),
          ),
          data: (items) => items.isEmpty
              ? _empty('No cameras added.', Icons.videocam_outlined, 2)
              : CameraGrid(cameras: items.take(2).toList()),
        ),
      ],
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('HomeHub'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 24),
            child: Tooltip(
              message: 'Device commands stay on your local network',
              child: Chip(
                avatar: Icon(Icons.lan_outlined, size: 16),
                label: Text('LOCAL ONLY'),
              ),
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) => ListView(
          padding: EdgeInsets.all(constraints.maxWidth >= 800 ? 24 : 16),
          children: [
            Text(
              'Your home, in harmony.',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: -1,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'One calm space. Everything within reach.',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _summary(
                  context,
                  Icons.lightbulb_outline,
                  'Lights / ${lights.asData?.value.length ?? 0} configured',
                  1,
                ),
                _summary(
                  context,
                  Icons.videocam_outlined,
                  'Cameras / ${cameras.asData?.value.length ?? 0} configured',
                  2,
                ),
              ],
            ),
            const SizedBox(height: 28),
            if (constraints.maxWidth >= 900)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 6, child: surveillance),
                  const SizedBox(width: 24),
                  Expanded(flex: 5, child: lighting),
                ],
              )
            else ...[
              lighting,
              const SizedBox(height: 24),
              surveillance,
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _summary(BuildContext context, IconData icon, String label, int tab) =>
      ActionChip(
        avatar: Icon(icon, size: 20),
        label: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(label),
        ),
        onPressed: () => onNavigate(tab),
      );

  Widget _empty(String label, IconData icon, int tab) => GlassPanel(
    child: SizedBox(
      width: double.infinity,
      child: Column(
        children: [
          const SizedBox(height: 16),
          Icon(icon, size: 40),
          const SizedBox(height: 16),
          Text(label),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => onNavigate(tab),
            icon: const Icon(Icons.add),
            label: Text(tab == 1 ? 'Set up lighting' : 'Set up cameras'),
          ),
          const SizedBox(height: 16),
        ],
      ),
    ),
  );

  Widget _heading(
    BuildContext context,
    String title,
    String subtitle,
    int tab,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        IconButton(
          tooltip: 'View all ${tab == 1 ? 'Lights' : 'Cameras'}',
          onPressed: () => onNavigate(tab),
          icon: const Icon(Icons.arrow_forward),
        ),
      ],
    ),
  );
}
