import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage.dart';
import '../../core/local_network.dart';
import '../tv_sync/tv_sync_controller.dart';
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
    if (config.schedule?.enabled == true && ref.read(tvSyncProvider.exists)) {
      final sync = ref.read(tvSyncProvider);
      if (sync.status != TvSyncStatus.idle &&
          (sync.lightId == config.id || sync.lightId == previousId)) {
        throw const HomeHubException(
          'Stop TV Sync before enabling a schedule for this light.',
        );
      }
    }
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

  Future<void> savePreset(String id, int slot, LightPreset preset) async {
    preset.validate();
    RangeError.checkValidIndex(slot, const [0, 1, 2]);
    final config = (await future).firstWhere((item) => item.id == id);
    final presets = [...config.presets];
    presets[slot] = preset;
    await save(
      LightConfig.fromJson({
        ...config.toJson(),
        'presets': presets.map((item) => item?.toJson()).toList(),
      }),
    );
  }
}
