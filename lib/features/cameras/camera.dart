import '../../core/local_network.dart';

enum CameraStream { stream1, stream2 }

class CameraConfig {
  const CameraConfig({
    required this.id,
    required this.name,
    required this.host,
    required this.username,
    required this.password,
    this.port = 554,
    this.stream = CameraStream.stream1,
    this.panTilt = false,
    this.onvifPort = 2020,
    this.motionLightId,
    this.motionBrightness = 100,
    this.motionHue = 0,
    this.motionSaturation = 1,
    this.motionOffDelaySeconds = 20,
  });

  final String id, name, host, username, password;
  final int port;
  final CameraStream stream;
  final bool panTilt;
  final int onvifPort;
  final String? motionLightId;
  final double motionBrightness, motionHue, motionSaturation;
  final int motionOffDelaySeconds;

  void validate() {
    requireLocalAddress(host);
    if (name.trim().isEmpty || username.isEmpty || password.isEmpty) {
      throw const HomeHubException(
        'Enter the camera name, camera-account username and password.',
      );
    }
    if (port < 1 || port > 65535) {
      throw const HomeHubException('RTSP port must be between 1 and 65535.');
    }
    if ((panTilt || motionLightId != null) &&
        (onvifPort < 1 || onvifPort > 65535)) {
      throw const HomeHubException('ONVIF port must be between 1 and 65535.');
    }
    if (!motionBrightness.isFinite ||
        motionBrightness < 0 ||
        motionBrightness > 100 ||
        !motionHue.isFinite ||
        motionHue < 0 ||
        motionHue > 360 ||
        !motionSaturation.isFinite ||
        motionSaturation < 0 ||
        motionSaturation > 1 ||
        motionOffDelaySeconds < 1 ||
        motionOffDelaySeconds > 300) {
      throw const HomeHubException('Check the motion-light settings.');
    }
  }

  String rtspUrl({bool preview = false}) {
    validate();
    final path = preview ? CameraStream.stream2.name : stream.name;
    return 'rtsp://${Uri.encodeComponent(username)}:${Uri.encodeComponent(password)}@$host:$port/$path';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'username': username,
    'password': password,
    'port': port,
    'stream': stream.name,
    'panTilt': panTilt,
    'onvifPort': onvifPort,
    'motionLightId': motionLightId,
    'motionBrightness': motionBrightness,
    'motionHue': motionHue,
    'motionSaturation': motionSaturation,
    'motionOffDelaySeconds': motionOffDelaySeconds,
  };

  factory CameraConfig.fromJson(Map<String, dynamic> json) => CameraConfig(
    id: json['id'] as String,
    name: json['name'] as String,
    host: json['host'] as String,
    username: json['username'] as String,
    password: json['password'] as String,
    port: json['port'] as int,
    stream: CameraStream.values.byName(json['stream'] as String),
    panTilt: json['panTilt'] as bool? ?? false,
    onvifPort: json['onvifPort'] as int? ?? 2020,
    motionLightId: json['motionLightId'] as String?,
    motionBrightness: (json['motionBrightness'] as num?)?.toDouble() ?? 100,
    motionHue: (json['motionHue'] as num?)?.toDouble() ?? 0,
    motionSaturation: (json['motionSaturation'] as num?)?.toDouble() ?? 1,
    motionOffDelaySeconds: json['motionOffDelaySeconds'] as int? ?? 20,
  );
}
