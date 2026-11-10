import 'dart:io';

import 'package:homehub/core/local_network.dart';
import 'package:tinytuya/tinytuya.dart';

Future<void> main() async {
  stdout.writeln('Listening for local Tuya advertisements for 12 seconds...');
  try {
    final devices = await deviceScan(scanTime: 12, verbose: false);
    final localDevices = devices.where((device) => isPrivateIpv4(device.ip));
    if (localDevices.isEmpty) {
      stdout.writeln(
        'No Tuya advertisements received. This does not prove LAN control is unsupported.',
      );
      return;
    }
    for (final device in localDevices) {
      stdout.writeln('IP: ${device.ip}');
      stdout.writeln('Device ID: ${device.gwId ?? 'not advertised'}');
      stdout.writeln('Protocol: ${device.version ?? 'not advertised'}');
      stdout.writeln('MAC: ${device.mac ?? 'not advertised'}');
      stdout.writeln();
    }
  } catch (_) {
    stderr.writeln(
      'Local discovery failed. Check LAN access and that UDP ports 6666, 6667 and 7000 are available.',
    );
    exitCode = 1;
  }
}
