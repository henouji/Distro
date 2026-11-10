import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/components/feedback.dart';
import '../../lights_controller.dart';
import '../light_editor.dart';
import '../light_tile.dart';

class LightsScreen extends ConsumerWidget {
  const LightsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(
      title: const Text('Lights'),
      actions: [
        IconButton(
          tooltip: 'Add light',
          icon: const Icon(Icons.add),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => const LightEditor()),
          ),
        ),
      ],
    ),
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
          data: (lights) => RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(lightStatusProvider);
              await Future.wait(
                lights.map((config) async {
                  try {
                    await ref.read(lightStatusProvider(config).future);
                  } catch (_) {}
                }),
              );
            },
            child: ListView(
              padding: const EdgeInsets.all(16),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (lights.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('No lights added.')),
                  ),
                for (final config in lights)
                  LightTile(key: ValueKey(config.id), config: config),
              ],
            ),
          ),
        ),
  );
}
