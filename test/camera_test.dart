import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:homehub/core/local_network.dart';
import 'package:homehub/core/storage.dart';
import 'package:homehub/features/cameras/camera.dart';
import 'package:homehub/features/cameras/camera_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  const camera = CameraConfig(
    id: 'test',
    name: 'Door',
    host: '192.168.1.40',
    username: 'user@home',
    password: 'pass:/?#%',
  );

  test('RTSP credentials are escaped and previews use stream2', () {
    final preview = Uri.parse(camera.rtspUrl(preview: true));
    expect(preview.host, camera.host);
    expect(preview.port, 554);
    expect(preview.path, '/stream2');
    expect(preview.userInfo, 'user%40home:pass%3A%2F%3F%23%25');
    expect(Uri.parse(camera.rtspUrl()).path, '/stream1');
  });
  test('camera configuration round-trips through secure JSON', () {
    expect(CameraConfig.fromJson(camera.toJson()).toJson(), camera.toJson());
  });
  test('camera add, edit and delete persist in secure storage', () async {
    final container = ProviderContainer.test();
    await container.read(camerasProvider.future);
    final controller = container.read(camerasProvider.notifier);
    await controller.save(camera);
    expect(container.read(camerasProvider).requireValue.single.name, 'Door');
    final edited = CameraConfig.fromJson({
      ...camera.toJson(),
      'name': 'Front Door',
    });
    await controller.save(edited);
    final stored = await container.read(vaultProvider).readList('cameras');
    expect(stored.single['name'], 'Front Door');
    expect(stored.single['password'], camera.password);
    await controller.delete(camera.id);
    expect(await container.read(vaultProvider).readList('cameras'), isEmpty);
  });
  test('reject public IPs, hostnames and invalid ports', () {
    for (final host in [
      '1.1.1.1',
      'camera.example.com',
      '192.168.1.2/stream1',
    ]) {
      expect(
        () => CameraConfig(
          id: 'test',
          name: 'Bad',
          host: host,
          username: 'user',
          password: 'pass',
        ).rtspUrl(),
        throwsA(isA<HomeHubException>()),
      );
    }
    expect(
      () => const CameraConfig(
        id: 'test',
        name: 'Bad',
        host: '10.0.0.1',
        username: 'user',
        password: 'pass',
        port: 0,
      ).validate(),
      throwsA(isA<HomeHubException>()),
    );
  });
}
