import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage.dart';
import 'camera.dart';

final camerasProvider =
    AsyncNotifierProvider<CamerasController, List<CameraConfig>>(
      CamerasController.new,
    );

class CamerasController extends AsyncNotifier<List<CameraConfig>> {
  @override
  Future<List<CameraConfig>> build() async =>
      (await ref.watch(vaultProvider).readList('cameras'))
          .map(CameraConfig.fromJson)
          .toList();

  Future<void> save(CameraConfig camera) async {
    camera.validate();
    final current = await future;
    final next = [...current.where((item) => item.id != camera.id), camera];
    await ref
        .read(vaultProvider)
        .writeList('cameras', next.map((item) => item.toJson()).toList());
    state = AsyncData(next);
  }

  Future<void> delete(String id) async {
    final next = (await future).where((item) => item.id != id).toList();
    await ref
        .read(vaultProvider)
        .writeList('cameras', next.map((item) => item.toJson()).toList());
    state = AsyncData(next);
  }
}
