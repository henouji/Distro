# HomeHub

Android app for direct Tuya Wi-Fi light control and local Tapo RTSP viewing.
Flutter stable, Material 3, Riverpod, Android 7.0+ (minSdk 24).

## Local-Only Architecture

This implementation follows the approved change from Tuya Cloud OpenAPI to
direct LAN control. HomeHub does not call Tuya Cloud, sign cloud requests, use
cloud access tokens, request a Tuya login, or fall back to the cloud. There is
no backend, analytics SDK, or remote font/image fetching. Device destinations
must be literal private IPv4 addresses in 10/8, 172.16/12, or 192.168/16.
Public addresses, DNS names, IPv6 and arbitrary RTSP paths are rejected.

Lights use the published Dart `tinytuya` LAN client over TCP 6668; cameras use
`media_kit` over RTSP/TCP. The LAN client library also offers a cloud API, but
HomeHub never instantiates it. There are no application HTTP requests, so Dio
is not needed after the architecture change. Development, package downloads
and GitHub builds require internet; normal device management does not.

**This is not a network firewall.** Android's INTERNET permission is also
required for LAN sockets. HomeHub validates configured destinations, but cannot
prevent cameras or bulbs from calling their manufacturers, or enforce an
egress policy on native media libraries. For strict isolation, block WAN access
for the phone/app and IoT devices using your router/firewall, allow their local
traffic, and verify operation with internet disconnected. Do not port-forward
RTSP or Tuya ports. Use a trusted home network; RTSP is not encrypted.

All light local keys and camera credentials/configuration are stored using
`flutter_secure_storage` with encrypted Android preferences. Only theme and
preview settings go into `shared_preferences`. Android app backup is disabled.
Uninstalling or clearing app data removes configuration. There are no default
credentials. Never commit device key files or publish native playback logs.

## Firefly FSB109CD Compatibility

The [manufacturer's FSB109CD page](https://www.fireflyelectric.com/product/firefly-smart-led-bulb-cctdimming-9w/)
identifies it as a 9W dimmable, tunable-white bulb using the Tuya app and
2.4 GHz Wi-Fi without a hub. It is not established as a Bluetooth-only bulb.
HomeHub does not implement BLE control or request Bluetooth permissions.

**LAN compatibility for your specific bulb and firmware is unverified.**
Failure to control it offline in Smart Life does not prove that the local Tuya
protocol is unavailable. HomeHub needs its actual device ID, local key, IP,
protocol version and DP mapping. A model number alone cannot supply these.
If the firmware does not expose a compatible LAN protocol, HomeHub cannot
control it under the local-only requirement. No cloud workaround is enabled.

## Build and Install

1. Install [Flutter stable](https://docs.flutter.dev/get-started/install),
	Java 17 and Android Studio's Android SDK/command-line tools.
2. Use `flutter doctor -v` to resolve Android toolchain issues. Install the SDK
	platform/build tools requested by your Flutter version.
3. Accept the Android SDK licenses with `flutter doctor --android-licenses`.
4. From the project root run:

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

The APK is `build/app/outputs/flutter-apk/app-debug.apk`.
Connect an Android phone with USB debugging enabled and run `flutter run`, or
install with `adb install -r build/app/outputs/flutter-apk/app-debug.apk`.
Debug builds use a development signing key and are not Play Store releases.
Keep `pubspec.lock` in source control. The project was analyzed and tested with
Flutter 3.47.9 / Dart 3.13.7; the workflow follows Flutter's stable channel.

## Configure Lights

1. Pair the bulb in Tuya Smart or Smart Life, if it is not already paired.
2. Reserve its private IP in your router's DHCP settings. Keep the phone on the
	same reachable network; guest Wi-Fi/client isolation can prevent access.
3. Obtain the device ID, local key and actual protocol version. If you already
	have them, skip the optional cloud-assisted provisioning section below.
4. Close Smart Life/Tuya Smart before testing. Some bulbs allow only one local
	TCP client at a time.
5. In HomeHub open Settings > Lights > Add, or Lights > Add. Enter the name,
	device ID, private IP, 16-byte local key and protocol version.
6. Select a DP layout. The modern preset uses power 20, mode 21, brightness 22,
	temperature 23, brightness range 10-1000. Legacy uses 1, 2, 3, 4 and 25-255.
	These are common Tuya presets, **not verified FSB109CD mappings**.
7. Expand Data Points to enter the device's actual mapping. Leave unsupported
	optional fields empty. IDs must be unique and in 1-255. The temperature
	range is 0 through Value maximum. A mode DP can be omitted for CCT devices
	without a mode selector.
8. Leave Color DP empty for FSB109CD. Only configure it for a verified RGB
	device. Modern RGB uses HSV16 encoding; legacy RGB uses RGB8+HSV encoding.
9. Tap Test connection, then Save Light. Saving does not require the device to
	be online. Test connection reads status without changing the light.

The Lights screen shows online state, power and supported controls. Brightness
and temperature controls select white mode when a mode DP is configured. Color
selects colour mode. Commands are sent on slider release, serialized per bulb,
and followed by a status refresh. Unsupported controls are hidden. Pull down
to refresh or use Retry on an offline light. The options menu edits/deletes it.

LAN uses numeric DP IDs, not Cloud API names such as `switch_led`,
`bright_value_v2` or `colour_data_v2`. Legacy/modern/custom mappings replace
Cloud API DP-name negotiation. No UID-based cloud device enumeration occurs.

### Optional One-Time Cloud-Assisted Key Retrieval

**This step contacts Tuya's servers outside HomeHub.** Skip it if you require
zero cloud use even during provisioning. There is no verified cloud-free key
retrieval procedure for the FSB109CD documented here; without a local key,
encrypted local commands cannot be sent. Do not post keys in chat or issues.

The [Python TinyTuya setup guide](https://github.com/jasonacox/tinytuya#setup-wizard---getting-local-keys)
provides a maintained provisioning path. Portal labels, API availability and
trial terms can change.

1. Sign up at [Tuya Developer Platform](https://iot.tuya.com/). Under Cloud >
	Development create a Smart Home cloud project. Choose the data center that
	matches your app account, not simply the geographically closest one.
2. On the project's Overview/Authorization page find **Access ID / Client ID**
	and **Access Secret / Client Secret**. Keep both private. Authorize the IoT
	Core and Authorization API services required by TinyTuya; an active trial
	or subscription may be necessary. Check terms before subscribing.
3. In the project's Devices tab select Link Tuya App Account > Add App Account.
	Scan the QR code using the scanner in the Tuya Smart/Smart Life app that
	owns your bulbs and confirm linking. If no devices appear, check the data
	center and that you linked the correct app account.
4. The linked app-account entry shows the account **UID**. This is not a bulb's
	device ID. Keep it for reference; local-only HomeHub does not request it.
	Copy the bulb's device ID from the device list or app device information.
5. On a trusted computer install Python TinyTuya using
	`python -m pip install tinytuya`, then run `python -m tinytuya wizard`.
	Enter the project Access ID, Secret, region and sample device ID locally.
	Do not send these credentials to HomeHub or commit generated files.
6. The wizard retrieves device local keys and writes a device configuration
	file. Transfer your bulb's key into HomeHub's encrypted local setup form.
	Keep the key file private and delete it securely when no longer needed.
7. `python -m tinytuya scan` performs local discovery and can show IP, device
	ID and protocol version. Permit LAN UDP 6666/6667/7000 and TCP 6668 if using
	that external tool. HomeHub itself uses manual setup, not discovery.
8. After successful local control, disconnect WAN access and repeat power,
	brightness and temperature tests. Resetting/re-pairing a bulb changes its
	local key, so update HomeHub after doing so.

## Configure Tapo Cameras

1. Use a Tapo model/firmware that supports RTSP. Some battery-powered models do
	not support continuous RTSP streams. Check the model's TP-Link documentation.
2. In the Tapo app open the camera > Settings > Advanced Settings > Camera
	Account (labels vary). Create a dedicated camera username and strong password.
	This is **not** your TP-Link cloud account. Enable RTSP/third-party access if
	your model has a separate setting.
3. Find its private IP in the app or router, and reserve that IP using DHCP.
4. In HomeHub Settings > Cameras > Add, enter a name, IP, RTSP port (default
	554), camera-account username/password, and full-screen quality.
5. Tap Test connection. This opens a real playback test; a picture confirms
	streaming works. Invalid credentials, disabled RTSP and network failures
	may produce the same native error, so check all three if it fails.
6. Save Camera. Repeat for additional cameras. Use each tile's options menu
	to edit or delete it.

URL structure: `rtsp://USER:PASS@PRIVATE_IP:554/stream1`. HomeHub percent-encodes
credentials; you enter username/password normally, without URL escaping.
Grid previews always use stream2 and start muted. Full-screen defaults to
stream1; selecting Low explicitly opts into stream2 for full-screen too.
Tap the tile/open icon for a full-screen live view and use its mute button
to toggle audio. Incoming audio only; talk-back is not implemented.

Streams use TCP, a 15-second initial/stall timeout and Retry. Streams are
released when backgrounded, covered by another route, or removed from the
screen. Reduce concurrent camera load by disabling live previews in Settings.
Camera firmware may limit concurrent sessions; HomeHub releases previews when
opening the full-screen route. Many previews can still strain a phone/camera.

**TODO: ONVIF PTZ.** Controls are intentionally absent. A future implementation
must authenticate against local port 2020, discover media/PTZ profiles and
capabilities, and implement ContinuousMove plus reliable Stop on release,
timeout and lifecycle changes. Do not display PTZ for unsupported fixed cameras.

## Troubleshooting

- Light offline: check power, reserved IP, key, actual protocol version and DP
  mapping. Close competing Tuya clients. LAN support is firmware-dependent.
- Wrong local key: obtain the current key after re-pairing. HomeHub never
  silently retries through the cloud.
- Camera timeout: check the local camera account, RTSP availability, port,
  private IP and Wi-Fi client isolation. Retry or select low full-screen quality.
- Cleartext traffic is allowed for local RTSP. Android cannot express a dynamic
  private-CIDR allowlist in the manifest; application validation limits configured
  addresses. Router rules provide a stronger boundary.
- Credentials cannot be loaded: retry. Do not clear storage unless you are
  prepared to re-enter all configuration. Raw device/native errors are not
  shown in the UI because they may include sensitive information.

## GitHub Actions

`.github/workflows/build-apk.yml` runs on every push and manual dispatch. It
sets up Java 17 and Flutter stable, resolves packages, runs analysis and tests,
builds the debug APK, and uploads artifact **homehub-apk** for 14 days.

Push this project to GitHub, open Actions > Build HomeHub APK, and download
homehub-apk from a successful run. No device secrets or GitHub repository
secrets are required. The workflow has not been run merely by creating this file.

## Project Layout and Verification

```text
lib/
  main.dart
  core/                   # App, navigation, LAN guard, encrypted storage
  features/lights/        # LightProvider, Tuya LAN adapter, setup and controls
  features/cameras/       # Secure camera list, RTSP playback and setup
  features/settings/      # Persisted settings and device management
test/                     # LAN guard, adapter, camera and widget tests
android/                  # Android-only Flutter host and Gradle wrapper
.github/workflows/        # Debug APK build/artifact workflow
```

Tests cover address restrictions, URL escaping, stream choice, DP scaling,
RGB encoding, secure configuration CRUD, adapter errors/cleanup and phone-width
navigation/forms/theme persistence.
They do not emulate real Tuya firmware or native Android RTSP decoding.
Validate both integrations on physical devices with WAN blocked before relying
on local-only operation. No physical bulb or camera has been tested here.