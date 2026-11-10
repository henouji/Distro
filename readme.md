# HomeHub

Android app for direct Tuya Wi-Fi light control and local Tapo RTSP viewing.
Flutter stable, Material 3, Riverpod, Android 7.0+ (minSdk 24).

## Tablet Command Center

The interface uses translucent, blurred glass panels with light and dark themes.
At 760 logical pixels and wider, navigation moves to a persistent side rail;
wide dashboards show cameras and lighting side by side. Smaller screens retain
bottom navigation and a scrollable single-column layout. Lighting cards form a
responsive grid with touch-sized controls. No remote images or fonts are loaded.

Light cards expose brightness, warm-to-cool white temperature and a color picker
with a touch color wheel, brightness slider, precise hue/saturation sliders and
color shortcuts, when supported by the bulb's
configured data points. Temperature remains a normalized percentage: no Kelvin
range is assumed. The FSB109CD is tunable white, not RGB.

## Dynamic lighting and notification controls

Open **Lights > Dynamic lighting** (the clock icon).

- Create a timeline for each light with brightness and warm-to-cool temperature
  at two or more distinct times. Choose the weekdays and enable the schedule.
  Brightness and temperature DPs must both be configured; RGB is not required.
- Press **Start schedules** on one HomeHub device on your home Wi-Fi.
  The light turns on at the first time, transitions linearly between points,
  and holds the last setting until local midnight. Nothing is sent before the
  first time or on unselected days. There are no overnight segments or
  automatic power-off events. At 0% brightness the configured bulb minimum
  applies; this does not mean power off.
- Timelines use the controller device's local clock and timezone, including
  clock changes. Updates run approximately every 30 seconds, plus LAN request
  time. Edits take effect at the next update. Missed intervals are not replayed:
  reconnecting applies the current value. An unreachable light does not block
  other lights; errors appear in this screen and the notification, with retries
  on subsequent updates.
- For quick access, choose a **Notification bulb** and press **Show notification
  controls**. The collapsed notification exposes power, brightness in 10%
  steps, **White** (alternates warm/cool) and **Color** (cycles
  Red/Amber/Green/Blue) where supported, without expanding. Expanding is optional
  for individual white/color presets and detailed status. On Android 8+, the
  foreground notification requests full-card colorization using HomeHub's
  light teal or dark blue glass-surface color, with translucent buttons rather
  than a separately framed inner panel. Android controls the final rendering
  and notification shade; custom notifications cannot reproduce live backdrop blur.
  Color brightness changes preserve hue and saturation. **Refresh** reads the
  bulb again; status also refreshes on the background update cycle.
  **Hide notification controls** leaves schedules running.
- Android runs an independent Flutter engine in a connected-device foreground
  service, so these controls and schedules do not depend on the app's screen
  or activity staying open. Allow notification permission. Use **Battery
  settings** to exempt HomeHub from Android battery optimization; Doze and
  manufacturer battery restrictions can otherwise interrupt screen-off Wi-Fi.
  Keeping the CPU and Wi-Fi awake consumes additional power: a plugged-in
  controller is recommended. Force-stop, Android's active-app Stop action or a
  reboot ends execution; reopen HomeHub and start it again. No boot receiver
  or exact alarms are installed.
- **Stop schedules** leaves the lights unchanged and keeps pinned notification
  controls. **Stop all** in the notification ends both. Manual light/notification
  changes are overwritten at the next active schedule update.
- Disable a light's schedule before TV Sync and hide notification controls
  before starting capture, to avoid competing Tuya connections. Start
  automation on only one HomeHub device per bulb.

Timelines are saved with light configuration in encrypted storage. The native
service stores only its schedule-running flag and selected notification light
ID in private preferences; keys and other bulb configuration stay in the vault.

## TV Sync

Install HomeHub on an Android / Google TV (for example a Xiaomi A Pro) and open
the **TV** tab to make a light follow what is on screen. Choose a light,
press **Start TV Sync** and accept Android's screen-capture prompt, then press
Home and play something; the light keeps following in the background while
a "TV Sync is running" notification is active.

- The TV's own screen is mirrored into a 64-pixel-wide virtual display
  (MediaProjection in a `mediaProjection` foreground service). Letterbox bars
  are ignored; vivid pixels define the color and average luma the brightness.
  Frames are processed on the TV; nothing leaves the local network.
- Color bulbs (color and mode DPs configured) follow hue, saturation and
  brightness. Tunable-white bulbs such as the FSB109CD follow brightness and
  shift warmer or cooler with the picture.
- Brightness rises quickly and fades more slowly so the light "breathes"
  rather than flickers. Darkest/brightest brightness and smoothness are
  adjustable. Color sampling and light updates are capped at 5 per second
  by default to reduce playback load, over one persistent
  Tuya LAN connection. Sync uses individual DP writes, matching the normal
  light controls; the Tuya library's bulk-write helper nests the payload
  incorrectly and is not used.
- Use a release build on the TV (`flutter build apk --release`), not a debug
  build, to avoid development overhead during playback. Screen mirroring
  still uses TV graphics resources and can cause stutter on some TVs; stop
  sync if playback is affected. The sampling cap limits color processing,
  not the TV compositor's mirroring rate.
- When sync stops, the light's previous power, brightness and temperature are
  restored. While syncing, other Tuya clients cannot reach the bulb.
- DRM-protected apps (Netflix, Disney+ and similar) usually capture as black,
  so the light stays at the darkest setting during them. Expect a few hundred
  milliseconds of lag from capture plus the bulb's own fade.

### Control the TV from a tablet

The **TV** tab shows TV Sync on a TV and a remote control on tablets/phones.

1. On the TV, open HomeHub → **TV** and turn on **Tablet control**. It shows
   the TV's IP address and a 6-digit pairing code.
2. On the tablet, open HomeHub → **TV**, enter the IP and code, and press
   **Pair**.
3. The tablet now shows what is playing on the TV, lists the TV's apps (tap
   one to open it), and has a **Light Sync** switch, light picker and sliders.
   **Send my lights to the TV** copies the tablet's light setup to the TV.

Grant these once over adb (Wi-Fi debugging) so remote control works while
another app is in front on the TV:

```powershell
adb -s <tv-ip>:5555 shell appops set com.homehub.homehub SYSTEM_ALERT_WINDOW allow  # open apps / start sync from the background
adb -s <tv-ip>:5555 shell appops set com.homehub.homehub GET_USAGE_STATS allow      # report the app that is playing
adb -s <tv-ip>:5555 shell appops set com.homehub.homehub PROJECT_MEDIA allow        # skip the capture prompt (may be ignored by some TV firmware)
```

- The TV listens on port 47870 and only answers private-network addresses.
  Pairing issues a random token; the TV stores only its SHA-256 hash.
  **Forget paired tablets** on the TV revokes every tablet.
- Traffic is plain HTTP on your LAN, like the cameras' RTSP: anyone on the
  home Wi-Fi could read the token or the light keys sent by **Send my lights**.
- The server runs inside HomeHub on the TV. While Tablet control or sync is on,
  Back on the TV sends HomeHub to the background instead of closing it, but
  Android can still stop a backgrounded app; reopen HomeHub on the TV if the
  tablet cannot reach it.

## Local-Only Architecture

This implementation follows the approved change from Tuya Cloud OpenAPI to
direct LAN control. HomeHub does not call Tuya Cloud, sign cloud requests, use
cloud access tokens, request a Tuya login, or fall back to the cloud. There is
no backend, analytics SDK, or remote font/image fetching. Device destinations
must be literal private IPv4 addresses in 10/8, 172.16/12, or 192.168/16.
Public addresses, DNS names, IPv6 and arbitrary RTSP paths are rejected.

Lights use the published Dart `tinytuya` LAN client over TCP 6668; cameras use
`media_kit` over RTSP/TCP. The LAN client library also offers a cloud API, but
HomeHub never instantiates it. Opt-in camera movement uses authenticated ONVIF
SOAP over local HTTP on the configured camera port (C200 default: 2020).
Development, package downloads
and GitHub builds require internet; normal device management does not.

**This is not a network firewall.** Android's INTERNET permission is also
required for LAN sockets. HomeHub validates configured destinations, but cannot
prevent cameras or bulbs from calling their manufacturers, or enforce an
egress policy on native media libraries. For strict isolation, block WAN access
for the phone/app and IoT devices using your router/firewall, allow their local
traffic, and verify operation with internet disconnected. Do not port-forward
RTSP or Tuya ports. Use a trusted home network; RTSP is not encrypted.

All light local keys and camera credentials/configuration are stored using
`flutter_secure_storage` with encrypted Android preferences. Only theme, preview
and TV Sync (selected light ID and slider) settings go into
`shared_preferences`; the native lighting service also stores its running flag
and selected notification light ID in private preferences. Android app backup
is disabled.
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
In **Choose light color**, tap or drag around the wheel to select hue and move
toward its center for less saturation. Adjust **Brightness**, then tap **Apply**
to send the chosen color and brightness together. Wheel, slider and shortcut
changes stay local until Apply; Cancel leaves the bulb unchanged. The brightness
slider on the light card controls white-mode brightness.

Each light has exactly three user-configurable preset slots, visible on its
dashboard and Lights cards. Tap **Set preset** to name a slot and choose white
temperature/brightness or RGB color/brightness (where configured). **Save preset**
stores it locally without changing the bulb. Tap its name to apply it and turn
the light on; use its pencil button to edit it. Presets survive app restarts and
device-configuration edits. Offline lights cannot apply presets, but their
presets can still be edited. Tunable-white bulbs do not offer RGB presets.

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

### C200 Pitch / Yaw

Edit the C200 camera and enable **ONVIF pan / tilt**, leaving ONVIF port at 2020
unless your configuration differs. Existing cameras remain view-only until this
is explicitly enabled. Open the camera and tap **Connect controls**. HomeHub
reads the camera clock, authenticates with WS-Security UsernameToken digest,
discovers media/PTZ services and selects a PTZ-capable profile. No TP-Link cloud
account is used. Returned service addresses must match the configured private IP
and ONVIF port; redirects and proxy routing are disabled.
SOAP requests use an explicit UTF-8 content length because some camera firmware
closes connections when given chunked request bodies.

Use the arrows for pitch (up/down) and yaw (left/right). Each tap requests a
short continuous movement, followed by Stop after 250 ms. A one-second
camera-side timeout limits motion if the app is backgrounded or connectivity
fails. Stop movement is also available while a command is in flight. These are
relative directional controls, not absolute degree sliders: no measured angle,
home position or calibration is assumed. Errors are displayed in the panel.
Tablet landscape places controls alongside video; narrow layouts stack them.

This implementation has automated protocol tests but is not physically verified
against a C200. Firmware must support ONVIF continuous pan/tilt and its timeout.
If connection or movement is rejected, check the dedicated camera account,
third-party access settings, firmware, camera time and LAN reachability.
See [TP-Link's RTSP/ONVIF guide](https://www.tp-link.com/us/support/faq/2680/).
Local HTTP/RTSP is not encrypted; use a trusted network and block WAN access
at your router if required.

## Troubleshooting

- In the light editor, Detect protocol tries the selected version followed by
	other supported versions using read-only local status requests. Allow up to
	about a minute. A valid status response selects that version and displays
	numeric DP IDs without exposing the key or sending light commands. Review
	the mapping, Test connection, then Save Light. It does not retrieve a key or
	guarantee that control commands work; older 3.1 status reads may not validate
	the key. If detection fails, key/ID/IP mismatch or unsupported firmware remain
	possible causes.
- For key-free LAN discovery from this project, run
	`dart run tool/discover_lights.dart`. It listens for Tuya advertisements and
	prints only private IPs, device IDs, protocol versions and MAC addresses.
	It does not retrieve keys or contact Tuya Cloud. No advertisements can also
	mean UDP discovery is blocked; it does not establish lack of LAN support.
- Updated builds distinguish local connection failures, response timeouts,
	session-handshake failures and response-decoding failures. These are
	diagnostic categories, not proof of a particular root cause. A generic
	request failure does not establish that the DP mapping is wrong.
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
RGB encoding, secure configuration CRUD, adapter errors/cleanup, phone/tablet
navigation, forms/theme persistence, slider-release commands and RGB selection.
ONVIF tests cover digest authentication, clock alignment, service/profile
discovery, destination restrictions, bounded movement, Stop and error handling.
They do not emulate real Tuya firmware or native Android RTSP decoding.
Validate both integrations on physical devices with WAN blocked before relying
on local-only operation. No physical bulb or camera has been tested here.