Build an Android app called "HomeHub" using Flutter that controls my Tuya smart lights and shows my Tapo CCTV cameras in one place. Output a complete, buildable project plus a GitHub Actions workflow that produces a debug APK.

TECH
- Flutter (stable), Dart, Android only. minSdk 24.
- State management: Riverpod. Local storage: flutter_secure_storage for credentials, shared_preferences for settings.
- Video: media_kit (or flutter_vlc_player) for RTSP playback.
- HTTP: dio.

SCREENS
1. Home: two sections, "Lights" and "Cameras", with a bottom nav bar (Home, Lights, Cameras, Settings).
2. Lights: list all my Tuya devices with name, online status, on/off toggle, brightness slider, and color temperature slider (and color picker if supported). Pull-to-refresh.
3. Cameras: grid of camera tiles with live preview. Tap a tile for full-screen live view with a mute toggle and, if supported, pan/tilt controls (ONVIF PTZ).
4. Settings: forms to enter and save credentials (see below), plus a "Test connection" button for each service.

TUYA INTEGRATION
- Use the Tuya Cloud OpenAPI. The user provides: Access ID, Access Secret, data center region (e.g. Singapore, Western America, Central Europe, India), and the Tuya/Smart Life app account UID.
- Implement the HMAC-SHA256 request signing and token retrieval/refresh as per the Tuya OpenAPI docs.
- List devices by user UID, read device status, and send commands (switch_led, bright_value_v2, temp_value_v2, colour_data_v2). Handle both v1 and v2 DP code names gracefully.
- Put the Tuya code behind an abstract LightProvider interface so a local (LAN) provider can be added later.

TAPO CAMERAS
- The user adds cameras manually: name, IP address, port (default 554), camera-account username and password, and stream choice (stream1 = high quality, stream2 = low quality).
- RTSP URL format: rtsp://USER:PASS@IP:554/stream1
- Use stream2 for grid previews and stream1 for full-screen.
- PTZ via ONVIF (port 2020) if feasible; otherwise leave a clear TODO and hide the controls.
- Allow adding, editing and deleting multiple cameras.

REQUIREMENTS
- Never hard-code credentials; store them with flutter_secure_storage.
- Material 3, dark mode support, clean and simple UI.
- Handle errors clearly (offline device, wrong credentials, stream timeout) with user-friendly messages and retry.
- Add the Android permissions needed: INTERNET, ACCESS_NETWORK_STATE, and cleartext traffic allowed for local camera IPs.
- Organize the code as lib/{core,features/lights,features/cameras,features/settings}.
- Write a README with step-by-step instructions for getting the Tuya Access ID/Secret, linking my Smart Life account to the Tuya IoT project, finding the UID, and creating the Tapo camera account.

GITHUB ACTIONS
- Add .github/workflows/build-apk.yml that runs on push and manual dispatch: set up Java 17 and Flutter, run `flutter pub get`, `flutter analyze`, then `flutter build apk --debug`, and upload the APK as a workflow artifact named homehub-apk.

Work step by step: scaffold the project, implement Tuya, implement cameras, build the UI, add the workflow, then write the README. Ask me before making any assumptions that change the architecture.