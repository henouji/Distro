import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xml/xml.dart';

import '../../core/local_network.dart';
import 'camera.dart';

final cameraPtzFactoryProvider = Provider<PtzController Function(CameraConfig)>(
  (ref) =>
      (camera) => OnvifPtzController(camera),
);

abstract interface class PtzController {
  Future<void> connect();
  Future<void> nudge({required double yaw, required double pitch});
  Future<void> stop();
}

abstract interface class OnvifTransport {
  Future<String> send(Uri endpoint, String action, String envelope);
}

class HttpOnvifTransport implements OnvifTransport {
  @override
  Future<String> send(Uri endpoint, String action, String envelope) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4)
      ..findProxy = (_) => 'DIRECT';
    try {
      return await (() async {
        final request = await client.postUrl(endpoint);
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.contentTypeHeader,
          'application/soap+xml; charset=utf-8; action="$action"',
        );
        final body = utf8.encode(envelope);
        request.contentLength = body.length;
        request.add(body);
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          throw const HomeHubException(
            'ONVIF request rejected. Check the camera account, port and firmware.',
          );
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 1024 * 1024) {
            throw const HomeHubException('The ONVIF response is too large.');
          }
        }
        return utf8.decode(bytes);
      })().timeout(const Duration(seconds: 6));
    } on TimeoutException {
      throw const HomeHubException(
        'Camera controls timed out. Check home Wi-Fi.',
      );
    } on SocketException {
      throw const HomeHubException(
        'Cannot reach ONVIF. Check the camera IP and ONVIF port (C200: 2020).',
      );
    } on HttpException {
      throw const HomeHubException(
        'Camera control connection interrupted. Retry.',
      );
    } finally {
      client.close(force: true);
    }
  }
}

class OnvifPtzController implements PtzController {
  OnvifPtzController(this.camera, {OnvifTransport? transport})
    : _transport = transport ?? HttpOnvifTransport();

  final CameraConfig camera;
  final OnvifTransport _transport;
  Uri? _ptz;
  String? _profile;
  Duration _clockOffset = Duration.zero;
  static const _device = 'http://www.onvif.org/ver10/device/wsdl';
  static const _media = 'http://www.onvif.org/ver10/media/wsdl';
  static const _movement = 'http://www.onvif.org/ver20/ptz/wsdl';

  static Iterable<XmlElement> _elements(XmlNode node, String name) => node
      .descendants
      .whereType<XmlElement>()
      .where((element) => element.name.local == name);

  static String _escape(String value) => const HtmlEscape().convert(value);

  Uri _endpoint(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'http' ||
        uri.host != camera.host ||
        uri.port != camera.onvifPort ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.hasQuery) {
      throw const HomeHubException(
        'Camera returned an unexpected ONVIF address. Check the ONVIF port.',
      );
    }
    requireLocalAddress(uri.host);
    return uri;
  }

  Future<XmlDocument> _call(
    Uri endpoint,
    String namespace,
    String method,
    String body, {
    bool authenticate = true,
  }) async {
    var security = '';
    if (authenticate) {
      final random = Random.secure();
      final nonce = List<int>.generate(20, (_) => random.nextInt(256));
      final created = DateTime.now()
          .toUtc()
          .add(_clockOffset)
          .toIso8601String();
      final digest = base64Encode(
        sha1.convert([
          ...nonce,
          ...utf8.encode(created),
          ...utf8.encode(camera.password),
        ]).bytes,
      );
      const wsse =
          'http://docs.oasis-open.org/wss/2004/01/'
          'oasis-200401-wss-wssecurity-secext-1.0.xsd';
      const profile =
          'http://docs.oasis-open.org/wss/2004/01/'
          'oasis-200401-wss-username-token-profile-1.0';
      security =
          '<wsse:Security xmlns:wsse="$wsse" s:mustUnderstand="1">'
          '<wsse:UsernameToken>'
          '<wsse:Username>${_escape(camera.username)}</wsse:Username>'
          '<wsse:Password Type="$profile#PasswordDigest">$digest</wsse:Password>'
          '<wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/'
          'oasis-200401-wss-soap-message-security-1.0#Base64Binary">'
          '${base64Encode(nonce)}</wsse:Nonce>'
          '<wsu:Created xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/'
          'oasis-200401-wss-wssecurity-utility-1.0.xsd">$created</wsu:Created>'
          '</wsse:UsernameToken></wsse:Security>';
    }
    final response = await _transport.send(
      _endpoint(endpoint.toString()),
      '$namespace/$method',
      '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
          'xmlns:t="$namespace" xmlns:tt="http://www.onvif.org/ver10/schema">'
          '<s:Header>$security</s:Header><s:Body>'
          '<t:$method>$body</t:$method></s:Body></s:Envelope>',
    );
    final XmlDocument document;
    try {
      document = XmlDocument.parse(response);
    } on XmlException {
      throw const HomeHubException('Camera returned invalid ONVIF data.');
    }
    if (_elements(document, 'Fault').isNotEmpty) {
      throw const HomeHubException(
        'Camera rejected the control command. Check ONVIF support, '
        'camera account and camera date/time.',
      );
    }
    if (_elements(document, '${method}Response').isEmpty) {
      throw const HomeHubException('Camera did not confirm the ONVIF command.');
    }
    return document;
  }

  @override
  Future<void> connect() async {
    camera.validate();
    _ptz = null;
    _profile = null;
    if (!camera.panTilt) {
      throw const HomeHubException(
        'Enable ONVIF pan/tilt in the camera editor.',
      );
    }
    final device = Uri(
      scheme: 'http',
      host: camera.host,
      port: camera.onvifPort,
      path: '/onvif/device_service',
    );
    final clock = await _call(
      device,
      _device,
      'GetSystemDateAndTime',
      '',
      authenticate: false,
    );
    final utc = _elements(clock, 'UTCDateTime').firstOrNull;
    int part(String name, int min, int max) {
      final value = utc == null
          ? null
          : int.tryParse(_elements(utc, name).firstOrNull?.innerText ?? '');
      if (value == null || value < min || value > max) {
        throw const HomeHubException(
          'Cannot read the camera clock. Check its time settings.',
        );
      }
      return value;
    }

    final cameraTime = DateTime.utc(
      part('Year', 1970, 9999),
      part('Month', 1, 12),
      part('Day', 1, 31),
      part('Hour', 0, 23),
      part('Minute', 0, 59),
      part('Second', 0, 59),
    );
    _clockOffset = cameraTime.difference(DateTime.now().toUtc());
    final capabilities = await _call(
      device,
      _device,
      'GetCapabilities',
      '<t:Category>All</t:Category>',
    );
    Uri service(String name) {
      final node = _elements(capabilities, name).firstOrNull;
      final address = node == null
          ? null
          : _elements(node, 'XAddr').firstOrNull?.innerText;
      if (address == null) {
        throw const HomeHubException(
          'Camera does not advertise media and PTZ services.',
        );
      }
      return _endpoint(address);
    }

    final ptz = service('PTZ');
    final profiles = await _call(service('Media'), _media, 'GetProfiles', '');
    final profile = _elements(profiles, 'Profiles')
        .where((node) => _elements(node, 'PTZConfiguration').isNotEmpty)
        .firstOrNull
        ?.getAttribute('token');
    if (profile == null || profile.isEmpty) {
      throw const HomeHubException(
        'This camera has no ONVIF pan/tilt profile.',
      );
    }
    _profile = profile;
    _ptz = ptz;
  }

  void _requireConnected() {
    if (_ptz == null || _profile == null) {
      throw const HomeHubException('Connect camera controls first.');
    }
  }

  @override
  Future<void> nudge({required double yaw, required double pitch}) async {
    _requireConnected();
    if (!yaw.isFinite || !pitch.isFinite || yaw.abs() > 1 || pitch.abs() > 1) {
      throw const HomeHubException('Camera movement must be between -1 and 1.');
    }
    // The camera-side timeout bounds movement even if Wi-Fi or the app is lost.
    try {
      await _call(
        _ptz!,
        _movement,
        'ContinuousMove',
        '<t:ProfileToken>${_escape(_profile!)}</t:ProfileToken>'
            '<t:Velocity><tt:PanTilt x="${yaw * .35}" y="${pitch * .35}" '
            'space="http://www.onvif.org/ver10/tptz/PanTiltSpaces/'
            'VelocityGenericSpace"/></t:Velocity>'
            '<t:Timeout>PT1S</t:Timeout>',
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
    } finally {
      await stop();
    }
  }

  @override
  Future<void> stop() async {
    _requireConnected();
    await _call(
      _ptz!,
      _movement,
      'Stop',
      '<t:ProfileToken>${_escape(_profile!)}</t:ProfileToken>'
          '<t:PanTilt>true</t:PanTilt><t:Zoom>true</t:Zoom>',
    );
  }
}
