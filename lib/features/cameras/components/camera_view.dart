import 'package:flutter/material.dart';

import '../camera.dart';
import 'camera_player.dart';

class CameraView extends StatelessWidget {
  const CameraView({super.key, required this.camera, this.testing = false});
  final CameraConfig camera;
  final bool testing;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: Text(testing ? 'Test: ${camera.name}' : camera.name),
    ),
    body: SafeArea(child: CameraPlayer(camera: camera)),
  );
}
