import 'package:flutter/material.dart';

import '../camera.dart';
import 'camera_player.dart';
import 'camera_controls.dart';

class CameraView extends StatelessWidget {
  const CameraView({super.key, required this.camera, this.testing = false});
  final CameraConfig camera;
  final bool testing;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(testing ? 'Test: ${camera.name}' : camera.name)),
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final video = ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: CameraPlayer(camera: camera),
          );
          if (!camera.panTilt) {
            return Padding(padding: const EdgeInsets.all(16), child: video);
          }
          if (constraints.maxWidth >= 900) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Row(
                children: [
                  Expanded(child: video),
                  const SizedBox(width: 20),
                  SizedBox(
                    width: 300,
                    child: SingleChildScrollView(
                      child: CameraControls(camera: camera),
                    ),
                  ),
                ],
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              AspectRatio(aspectRatio: 16 / 9, child: video),
              const SizedBox(height: 16),
              CameraControls(camera: camera),
            ],
          );
        },
      ),
    ),
  );
}
