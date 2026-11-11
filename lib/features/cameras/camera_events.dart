import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

import '../../core/local_network.dart';
import 'camera.dart';
import 'camera_ptz.dart';

class MotionProbeResult {
  const MotionProbeResult({
    required this.eventsSupported,
    required this.motionObserved,
    required this.topics,
  });

  final bool eventsSupported;
  final bool motionObserved;
  final List<String> topics;
}

class OnvifMotionProbe {
  OnvifMotionProbe(this.camera, {OnvifTransport? transport})
    : _transport = transport ?? HttpOnvifTransport();

  final CameraConfig camera;
  final OnvifTransport _transport;
  Duration _clockOffset = Duration.zero;

  static const _device = 'http://www.onvif.org/ver10/device/wsdl';
  static const _events = 'http://www.onvif.org/ver10/events/wsdl';
  static const _notification = 'http://docs.oasis-open.org/wsn/b-2';
  static const _notificationAction =
      'http://docs.oasis-open.org/wsn/bw-2/SubscriptionManager';

  static Iterable<XmlElement> _elements(XmlNode node, String name) => node
      .descendants
      .whereType<XmlElement>()
      .where((element) => element.name.local == name);

  static String _escape(String value) => const HtmlEscape().convert(value);

  Uri _endpoint(
    String value, {
    Uri? base,
    String source = 'service',
    bool allowAlternatePort = false,
  }) {
    final parsed = Uri.tryParse(value);
    if (parsed == null) {
      throw HomeHubException('The ONVIF $source returned an invalid address.');
    }
    final uri = parsed.isAbsolute ? parsed : base?.resolveUri(parsed);
    if (uri == null ||
        uri.scheme != 'http' ||
        uri.host != camera.host ||
        uri.port < 1 ||
        uri.port > 65535 ||
        (!allowAlternatePort && uri.port != camera.onvifPort) ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      final returned = uri == null
          ? 'unresolved'
          : '${uri.scheme}://${uri.host}:${uri.port}';
      throw HomeHubException(
        'The ONVIF $source returned $returned; expected '
        'http://${camera.host}:${camera.onvifPort}.',
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
    String? actionNamespace,
    String? elementNamespace,
    String? actionName,
    bool allowAlternatePort = false,
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
      _endpoint(endpoint.toString(), allowAlternatePort: allowAlternatePort),
      '${actionNamespace ?? namespace}/${actionName ?? method}',
      '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
          'xmlns:t="${elementNamespace ?? namespace}" '
          'xmlns:tt="http://www.onvif.org/ver10/schema">'
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
      throw HomeHubException(
        'Camera rejected ONVIF $method. Check the camera account, firmware and camera date/time.',
      );
    }
    if (_elements(document, '${method}Response').isEmpty) {
      throw HomeHubException('Camera did not confirm ONVIF $method.');
    }
    return document;
  }

  Future<void> _alignClock(Uri device) async {
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
  }

  bool? _motionState(XmlNode message) {
    final topic = _elements(message, 'Topic').firstOrNull?.innerText ?? '';
    final motionTopic = topic.toLowerCase().contains('motion');
    for (final item in _elements(message, 'SimpleItem')) {
      final name = item.getAttribute('Name')?.toLowerCase() ?? '';
      final value = item.getAttribute('Value')?.toLowerCase();
      if (name.contains('motion') || (motionTopic && name == 'state')) {
        if (value == 'true') return true;
        if (value == 'false') return false;
      }
    }
    return null;
  }

  bool _isMotion(XmlNode message) => _motionState(message) == true;

  Future<({Uri pullPoint, List<String> topics})> _subscribe() async {
    camera.validate();
    if (camera.onvifPort < 1 || camera.onvifPort > 65535) {
      throw const HomeHubException('ONVIF port must be between 1 and 65535.');
    }
    final device = Uri(
      scheme: 'http',
      host: camera.host,
      port: camera.onvifPort,
      path: '/onvif/device_service',
    );
    await _alignClock(device);
    final capabilities = await _call(
      device,
      _device,
      'GetCapabilities',
      '<t:Category>All</t:Category>',
    );
    final eventNode = _elements(capabilities, 'Events').firstOrNull;
    final address = eventNode == null
        ? null
        : _elements(eventNode, 'XAddr').firstOrNull?.innerText;
    if (address == null || address.isEmpty) {
      throw const HomeHubException(
        'This camera does not advertise an ONVIF event service.',
      );
    }
    final events = _endpoint(address, source: 'Events service');
    final properties = await _call(events, _events, 'GetEventProperties', '');
    final topics =
        _elements(properties, 'Topic')
            .map((topic) {
              final name = topic.getAttribute('Name');
              return name == null
                  ? topic.innerText.trim()
                  : '$name ${topic.innerText}';
            })
            .where((topic) => topic.isNotEmpty)
            .toSet()
            .toList()
          ..sort();

    final subscription = await _call(
      events,
      _events,
      'CreatePullPointSubscription',
      '<t:InitialTerminationTime>PT60S</t:InitialTerminationTime>',
    );
    final subscriptionAddress = _elements(subscription, 'SubscriptionReference')
        .map(
          (reference) => _elements(reference, 'Address').firstOrNull?.innerText,
        )
        .whereType<String>()
        .firstOrNull;
    if (subscriptionAddress == null || subscriptionAddress.isEmpty) {
      throw const HomeHubException(
        'Camera did not return an ONVIF motion-event subscription address.',
      );
    }
    final pullPoint = _endpoint(
      subscriptionAddress,
      base: events,
      source: 'motion subscription',
      allowAlternatePort: true,
    );
    return (pullPoint: pullPoint, topics: topics);
  }

  Future<void> _unsubscribe(Uri pullPoint) => _call(
    pullPoint,
    _notification,
    'Unsubscribe',
    '',
    actionNamespace: _notificationAction,
    actionName: 'UnsubscribeRequest',
    allowAlternatePort: true,
  );

  Future<MotionProbeResult> listenForMotion({
    Duration duration = const Duration(seconds: 20),
    void Function()? onListening,
  }) async {
    if (duration <= Duration.zero || duration > const Duration(minutes: 2)) {
      throw const HomeHubException(
        'Motion test duration must be between 1 second and 2 minutes.',
      );
    }
    final subscription = await _subscribe();
    onListening?.call();
    final expires = DateTime.now().add(duration);
    var motionObserved = false;
    try {
      while (DateTime.now().isBefore(expires) && !motionObserved) {
        final response = await _call(
          subscription.pullPoint,
          _events,
          'PullMessages',
          '<t:Timeout>PT1S</t:Timeout><t:MessageLimit>10</t:MessageLimit>',
          allowAlternatePort: true,
        );
        motionObserved = _elements(
          response,
          'NotificationMessage',
        ).any(_isMotion);
      }
    } finally {
      await _unsubscribe(subscription.pullPoint);
    }
    return MotionProbeResult(
      eventsSupported: true,
      motionObserved: motionObserved,
      topics: subscription.topics,
    );
  }

  Future<void> watchMotion({
    required bool Function() shouldStop,
    required void Function(bool active) onState,
    void Function()? onReady,
    Duration duration = const Duration(seconds: 45),
  }) async {
    if (duration <= Duration.zero || duration > const Duration(seconds: 50)) {
      throw const HomeHubException(
        'Motion subscription duration must be between 1 and 50 seconds.',
      );
    }
    final subscription = await _subscribe();
    onReady?.call();
    final expires = DateTime.now().add(duration);
    try {
      while (!shouldStop() && DateTime.now().isBefore(expires)) {
        final response = await _call(
          subscription.pullPoint,
          _events,
          'PullMessages',
          '<t:Timeout>PT5S</t:Timeout><t:MessageLimit>10</t:MessageLimit>',
          allowAlternatePort: true,
        );
        for (final message in _elements(response, 'NotificationMessage')) {
          final state = _motionState(message);
          if (state != null) onState(state);
        }
      }
    } finally {
      await _unsubscribe(subscription.pullPoint);
    }
  }
}
