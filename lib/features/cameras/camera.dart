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
  });

  final String id, name, host, username, password;
  final int port;
  final CameraStream stream;

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
  };

  factory CameraConfig.fromJson(Map<String, dynamic> json) => CameraConfig(
    id: json['id'] as String,
    name: json['name'] as String,
    host: json['host'] as String,
    username: json['username'] as String,
    password: json['password'] as String,
    port: json['port'] as int,
    stream: CameraStream.values.byName(json['stream'] as String),
  );
}
