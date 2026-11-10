import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage.dart';
import 'light.dart';
import 'light_provider.dart';

final lightServiceProvider = Provider<LightProvider>(
  (ref) => TuyaLanLightProvider(),
);
final lightsProvider =
    AsyncNotifierProvider<LightsController, List<LightConfig>>(
      LightsController.new,
    );
final lightStatusProvider = FutureProvider.autoDispose
    .family<LightState, LightConfig>(
      (ref, config) => ref.watch(lightServiceProvider).read(config),
    );

class LightsController extends AsyncNotifier<List<LightConfig>> {
  @override
  Future<List<LightConfig>> build() async =>
      (await ref.watch(vaultProvider).readList('lights'))
          .map(LightConfig.fromJson)
          .toList();

  Future<void> save(LightConfig config, {String? previousId}) async {
    config.validate();
    final current = await future;
    final next = [
      ...current.where((item) => item.id != config.id && item.id != previousId),
      config,
    ];
    await ref
        .read(vaultProvider)
        .writeList('lights', next.map((item) => item.toJson()).toList());
    state = AsyncData(next);
    ref.invalidate(lightStatusProvider);
  }

  Future<void> delete(String id) async {
    final next = (await future).where((item) => item.id != id).toList();
    await ref
        .read(vaultProvider)
        .writeList('lights', next.map((item) => item.toJson()).toList());
    state = AsyncData(next);
    ref.invalidate(lightStatusProvider);
  }
}
