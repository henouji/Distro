import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homehub/core/local_network.dart';
import 'package:homehub/features/cameras/camera.dart';
import 'package:homehub/features/cameras/camera_ptz.dart';
import 'package:xml/xml.dart';

const ptzCamera = CameraConfig(
  id: 'camera',
  name: 'C200',
  host: '192.168.1.40',
  username: 'camera<&user',
  password: 'test-password',
  panTilt: true,
);

class FakeOnvifTransport implements OnvifTransport {
  final requests = <({Uri endpoint, String method, XmlDocument document})>[];
  String serviceHost = ptzCamera.host;
  bool supportsPtz = true;
  bool failMove = false;
  bool failStop = false;
  bool malformed = false;
  bool missingConfirmation = false;

  @override
  Future<String> send(Uri endpoint, String action, String envelope) async {
    final method = action.split('/').last;
    requests.add((
      endpoint: endpoint,
      method: method,
      document: XmlDocument.parse(envelope),
    ));
    if (malformed) return 'not XML';
    if (missingConfirmation) return '<Envelope/>';
    final body = switch (method) {
      'GetSystemDateAndTime' =>
        '<UTCDateTime><Time><Hour>12</Hour><Minute>30</Minute><Second>0</Second>'
            '</Time><Date><Year>2026</Year><Month>11</Month><Day>10</Day>'
            '</Date></UTCDateTime>',
      'GetCapabilities' =>
        '<Capabilities>'
            '<Media><XAddr>http://$serviceHost:2020/onvif/media_service</XAddr></Media>'
            '<PTZ><XAddr>http://$serviceHost:2020/onvif/ptz_service</XAddr></PTZ>'
            '</Capabilities>',
      'GetProfiles' =>
        supportsPtz
            ? '<Profiles token="profile&amp;1"><PTZConfiguration/></Profiles>'
            : '<Profiles token="fixed"/>',
      'ContinuousMove' when failMove => '<Fault/>',
      'Stop' when failStop => '<Fault/>',
      _ => '',
    };
    return '<Envelope><Body><${method}Response>$body'
        '</${method}Response></Body></Envelope>';
  }
}

Iterable<XmlElement> elements(XmlNode node, String name) => node.descendants
    .whereType<XmlElement>()
    .where((element) => element.name.local == name);

void main() {
  test('SOAP uses UTF-8 content length instead of chunked transfer', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    const envelope = '<Envelope><Name>caf\u00e9</Name></Envelope>';
    final received = server.first.then((request) async {
      final length = request.contentLength;
      final transferEncoding = request.headers.value(
        HttpHeaders.transferEncodingHeader,
      );
      final body = await utf8.decoder.bind(request).join();
      request.response.write('<GetSystemDateAndTimeResponse/>');
      await request.response.close();
      return (length: length, transferEncoding: transferEncoding, body: body);
    });
    final response = await HttpOnvifTransport().send(
      Uri(
        scheme: 'http',
        host: server.address.address,
        port: server.port,
        path: '/onvif/device_service',
      ),
      'http://www.onvif.org/ver10/device/wsdl/GetSystemDateAndTime',
      envelope,
    );
    final request = await received;
    expect(request.length, utf8.encode(envelope).length);
    expect(request.transferEncoding, isNull);
    expect(request.body, envelope);
    expect(response, '<GetSystemDateAndTimeResponse/>');
  });

  test(
    'discovers local services and authenticates with a password digest',
    () async {
      final transport = FakeOnvifTransport();
      final controller = OnvifPtzController(ptzCamera, transport: transport);
      await controller.connect();
      expect(transport.requests.map((request) => request.method), [
        'GetSystemDateAndTime',
        'GetCapabilities',
        'GetProfiles',
      ]);
      expect(
        transport.requests.every(
          (request) =>
              request.endpoint.host == ptzCamera.host &&
              request.endpoint.port == 2020,
        ),
        isTrue,
      );
      final clock = transport.requests.first.document;
      expect(elements(clock, 'UsernameToken'), isEmpty);
      final authenticated = transport.requests[1].document;
      expect(
        elements(authenticated, 'Username').single.innerText,
        ptzCamera.username,
      );
      final created = elements(authenticated, 'Created').single.innerText;
      expect(DateTime.parse(created).year, 2026);
      expect(DateTime.parse(created).month, 11);
      final nonce = base64Decode(
        elements(authenticated, 'Nonce').single.innerText,
      );
      expect(nonce.length, 20);
      expect(
        elements(authenticated, 'Password').single.innerText,
        base64Encode(
          sha1.convert([
            ...nonce,
            ...utf8.encode(created),
            ...utf8.encode(ptzCamera.password),
          ]).bytes,
        ),
      );
      expect(authenticated.toXmlString(), isNot(contains(ptzCamera.password)));
    },
  );

  test(
    'movement uses discovered profile, bounded velocity, timeout and Stop',
    () async {
      final transport = FakeOnvifTransport();
      final controller = OnvifPtzController(ptzCamera, transport: transport);
      await controller.connect();
      await controller.nudge(yaw: -1, pitch: 1);
      final move = transport.requests[3];
      expect(move.endpoint.path, '/onvif/ptz_service');
      expect(
        elements(move.document, 'ProfileToken').single.innerText,
        'profile&1',
      );
      final velocity = elements(move.document, 'PanTilt').single;
      expect(velocity.getAttribute('x'), '-0.35');
      expect(velocity.getAttribute('y'), '0.35');
      expect(elements(move.document, 'Timeout').single.innerText, 'PT1S');
      expect(transport.requests.last.method, 'Stop');
      expect(
        elements(transport.requests.last.document, 'PanTilt').single.innerText,
        'true',
      );
    },
  );

  test(
    'Stop is attempted after a rejected movement and failures are surfaced',
    () async {
      final transport = FakeOnvifTransport()..failMove = true;
      final controller = OnvifPtzController(ptzCamera, transport: transport);
      await controller.connect();
      await expectLater(
        controller.nudge(yaw: 1, pitch: 0),
        throwsA(isA<HomeHubException>()),
      );
      expect(transport.requests.last.method, 'Stop');
      transport.failStop = true;
      await expectLater(controller.stop(), throwsA(isA<HomeHubException>()));
    },
  );

  test('rejects unexpected services without forwarding credentials', () async {
    for (final host in ['1.1.1.1', '192.168.1.99', 'camera.example.com']) {
      final transport = FakeOnvifTransport()..serviceHost = host;
      final controller = OnvifPtzController(ptzCamera, transport: transport);
      await expectLater(controller.connect(), throwsA(isA<HomeHubException>()));
      expect(transport.requests.length, 2);
      expect(
        transport.requests.every(
          (request) => request.endpoint.host == ptzCamera.host,
        ),
        isTrue,
      );
    }
  });

  test(
    'rejects unsupported, invalid, unconnected and disabled controls',
    () async {
      final transport = FakeOnvifTransport()..supportsPtz = false;
      final controller = OnvifPtzController(ptzCamera, transport: transport);
      await expectLater(controller.stop(), throwsA(isA<HomeHubException>()));
      await expectLater(controller.connect(), throwsA(isA<HomeHubException>()));
      transport.supportsPtz = true;
      await controller.connect();
      for (final yaw in [2.0, double.nan, double.infinity]) {
        await expectLater(
          controller.nudge(yaw: yaw, pitch: 0),
          throwsA(isA<HomeHubException>()),
        );
      }
      final disabled = CameraConfig.fromJson({
        ...ptzCamera.toJson(),
        'panTilt': false,
      });
      final disabledTransport = FakeOnvifTransport();
      await expectLater(
        OnvifPtzController(disabled, transport: disabledTransport).connect(),
        throwsA(isA<HomeHubException>()),
      );
      expect(disabledTransport.requests, isEmpty);
    },
  );

  test('malformed and unconfirmed responses fail explicitly', () async {
    for (final transport in [
      FakeOnvifTransport()..malformed = true,
      FakeOnvifTransport()..missingConfirmation = true,
    ]) {
      await expectLater(
        OnvifPtzController(ptzCamera, transport: transport).connect(),
        throwsA(isA<HomeHubException>()),
      );
    }
  });

  test(
    'old camera configuration stays view-only; ONVIF settings round-trip',
    () {
      final old = {...ptzCamera.toJson()}
        ..remove('panTilt')
        ..remove('onvifPort');
      expect(CameraConfig.fromJson(old).panTilt, isFalse);
      expect(CameraConfig.fromJson(old).onvifPort, 2020);
      expect(
        CameraConfig.fromJson(ptzCamera.toJson()).toJson(),
        ptzCamera.toJson(),
      );
      expect(
        () => CameraConfig.fromJson({
          ...ptzCamera.toJson(),
          'onvifPort': 0,
        }).validate(),
        throwsA(isA<HomeHubException>()),
      );
    },
  );
}
