import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/components/feedback.dart';
import '../../camera_controller.dart';
import '../camera_editor.dart';
import '../camera_tile.dart';

class CamerasScreen extends ConsumerWidget {
  const CamerasScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(
      title: const Text('Cameras'),
      actions: [
        IconButton(
          tooltip: 'Add camera',
          icon: const Icon(Icons.add),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => const CameraEditor()),
          ),
        ),
      ],
    ),
    body: ref
        .watch(camerasProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) => Center(
            child: RetryMessage(
              error: error,
              onRetry: () => ref.invalidate(camerasProvider),
            ),
          ),
          data: (cameras) => cameras.isEmpty
              ? const Center(child: Text('No cameras added.'))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: CameraGrid(cameras: cameras),
                ),
        ),
  );
}
