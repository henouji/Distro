import 'dart:io';

bool isPrivateIpv4(String host) {
  final address = InternetAddress.tryParse(host);
  if (address == null || address.type != InternetAddressType.IPv4) return false;
  final bytes = address.rawAddress;
  return bytes[0] == 10 ||
      (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
      (bytes[0] == 192 && bytes[1] == 168);
}

void requireLocalAddress(String host) {
  if (!isPrivateIpv4(host)) {
    throw const HomeHubException(
      'Use a private IPv4 address on your home network.',
    );
  }
}

class HomeHubException implements Exception {
  const HomeHubException(this.message);
  final String message;
  @override
  String toString() => message;
}

String friendlyError(Object error) => error is HomeHubException
    ? error.message
    : 'Connection failed. Check your Wi-Fi, device address and credentials, then retry.';
