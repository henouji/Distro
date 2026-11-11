import 'package:flutter_test/flutter_test.dart';
import 'package:homehub/core/local_network.dart';
import 'package:homehub/features/cameras/camera.dart';
import 'package:homehub/features/cameras/camera_events.dart';
import 'package:homehub/features/cameras/camera_ptz.dart';

const camera = CameraConfig(
  id: 'camera',
  name: 'C200C',
  host: '192.168.1.40',
  username: 'camera-user',
  password: 'test-password',
);

class FakeOnvifTransport implements OnvifTransport {
  final methods = <String>[];
  final endpoints = <Uri>[];
  String serviceHost = camera.host;
  String? motionValue = 'true';
  int subscriptionPort = 1025;
  List<String?>? motionEvents;

  @override
  Future<String> send(Uri endpoint, String action, String envelope) async {
    endpoints.add(endpoint);
    final actionName = action.split('/').last;
    final method = actionName == 'UnsubscribeRequest'
        ? 'Unsubscribe'
        : actionName;
    methods.add(method);
    final body = switch (method) {
      'GetSystemDateAndTime' =>
        '<UTCDateTime><Time><Hour>12</Hour><Minute>30</Minute><Second>0</Second>'
            '</Time><Date><Year>2026</Year><Month>11</Month><Day>10</Day>'
            '</Date></UTCDateTime>',
      'GetCapabilities' =>
        '<Events><XAddr>http://$serviceHost:2020/onvif/event_service</XAddr></Events>',
      'GetEventProperties' =>
        '<TopicSet><Topic Name="RuleEngine">CellMotionDetector</Topic></TopicSet>',
      'CreatePullPointSubscription' =>
        '<SubscriptionReference><Address>http://$serviceHost:$subscriptionPort/onvif/subscription</Address></SubscriptionReference>',
      'PullMessages' => _pullMessage(),
      _ => '',
    };
    return '<Envelope><Body><${method}Response>$body'
        '</${method}Response></Body></Envelope>';
  }

  String _pullMessage() {
    final value = motionEvents == null
        ? motionValue
        : motionEvents!.isEmpty
        ? null
        : motionEvents!.removeAt(0);
    if (value == null) return '';
    return '<NotificationMessage><Topic>RuleEngine/CellMotionDetector/Motion</Topic>'
        '<Message><SimpleItem Name="IsMotion" Value="$value"/></Message>'
        '</NotificationMessage>';
  }
}

void main() {
  test('discovers and receives an active motion event', () async {
    final transport = FakeOnvifTransport();
    final result = await OnvifMotionProbe(
      camera,
      transport: transport,
    ).listenForMotion(duration: const Duration(seconds: 1));

    expect(result.eventsSupported, isTrue);
    expect(result.motionObserved, isTrue);
    expect(result.topics, contains('RuleEngine CellMotionDetector'));
    expect(
      transport.endpoints.any(
        (endpoint) =>
            endpoint.path == '/onvif/subscription' && endpoint.port == 1025,
      ),
      isTrue,
    );
    expect(transport.methods, [
      'GetSystemDateAndTime',
      'GetCapabilities',
      'GetEventProperties',
      'CreatePullPointSubscription',
      'PullMessages',
      'Unsubscribe',
    ]);
  });

  test('does not count a cleared motion state as detection', () async {
    final transport = FakeOnvifTransport()..motionValue = 'false';
    final result = await OnvifMotionProbe(
      camera,
      transport: transport,
    ).listenForMotion(duration: const Duration(seconds: 1));

    expect(result.motionObserved, isFalse);
  });

  test('streaming watcher reports motion start and end states', () async {
    final transport = FakeOnvifTransport()..motionEvents = ['true', 'false'];
    final states = <bool>[];
    await OnvifMotionProbe(camera, transport: transport).watchMotion(
      shouldStop: () => states.length == 2,
      onState: states.add,
      duration: const Duration(seconds: 1),
    );

    expect(states, [true, false]);
    expect(transport.methods.last, 'Unsubscribe');
  });

  test(
    'rejects event service addresses outside the configured camera',
    () async {
      final transport = FakeOnvifTransport()..serviceHost = '192.168.1.99';
      final result = OnvifMotionProbe(
        camera,
        transport: transport,
      ).listenForMotion();
      await expectLater(
        result,
        throwsA(
          isA<HomeHubException>().having(
            (error) => error.message,
            'message',
            contains('192.168.1.99:2020'),
          ),
        ),
      );
      expect(transport.methods, ['GetSystemDateAndTime', 'GetCapabilities']);
    },
  );
}
