import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/components/feedback.dart';
import '../../lights_controller.dart';
import '../light_editor.dart';
import '../light_tile.dart';
import '../lighting_schedule_screen.dart';

class LightsScreen extends ConsumerWidget {
  const LightsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(
      title: const Text('Lights'),
      actions: [
        IconButton(
          tooltip: 'Dynamic lighting',
          icon: const Icon(Icons.schedule),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => const LightingScheduleScreen(),
            ),
          ),
        ),
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
            child: LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 1200
                    ? 3
                    : constraints.maxWidth >= 760
                    ? 2
                    : 1;
                final cardWidth =
                    (constraints.maxWidth - 32 - (columns - 1) * 16) / columns;
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (lights.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(32),
                          child: Center(child: Text('No lights added.')),
                        ),
                      Wrap(
                        spacing: 16,
                        children: [
                          for (final config in lights)
                            SizedBox(
                              width: cardWidth,
                              child: LightTile(
                                key: ValueKey(config.id),
                                config: config,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
  );
}
