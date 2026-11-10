import 'dart:math' as math;

import 'package:tinytuya/tinytuya.dart' as tuya;

import '../../core/local_network.dart';
import '../lights/light.dart';

/// Average picture information for one captured TV frame.
class ScreenColor {
  const ScreenColor({
    required this.red,
    required this.green,
    required this.blue,
    required this.luma,
  });

  /// Saturation-weighted average color, 0-255 per channel.
  final double red, green, blue;

  /// Overall scene brightness, 0-1.
  final double luma;

  factory ScreenColor.fromList(List<Object?> values) {
    double read(int index, double max) =>
        ((values[index] as num?)?.toDouble() ?? 0).clamp(0, max).toDouble();
    return ScreenColor(
      red: read(0, 255),
      green: read(1, 255),
      blue: read(2, 255),
      luma: read(3, 1),
    );
  }
}

enum SyncMode { color, white }

SyncMode syncModeFor(LightConfig config) {
  if (config.colorDp != null && config.modeDp != null) return SyncMode.color;
  if (config.brightnessDp != null) return SyncMode.white;
  throw const HomeHubException(
    'TV Sync needs a light with brightness or color data points.',
  );
}

class SyncSettings {
  const SyncSettings({
    this.minBrightness = 5,
    this.maxBrightness = 100,
    this.smoothing = .4,
  });

  /// Brightness percentages used for the darkest and brightest scenes.
  final double minBrightness, maxBrightness;

  /// 0 reacts instantly, 1 breathes slowly.
  final double smoothing;

  SyncSettings copyWith({
    double? minBrightness,
    double? maxBrightness,
    double? smoothing,
  }) => SyncSettings(
    minBrightness: minBrightness ?? this.minBrightness,
    maxBrightness: maxBrightness ?? this.maxBrightness,
    smoothing: smoothing ?? this.smoothing,
  );
}

/// What the light should show, independent of the bulb's DP encoding.
class LightFrame {
  const LightFrame({
    required this.hue,
    required this.saturation,
    required this.brightness,
    required this.temperature,
  });

  /// Hue 0-360, saturation 0-1, brightness and temperature 0-100.
  final double hue, saturation, brightness, temperature;

  (int, int, int) get rgb {
    final value = brightness.clamp(0, 100) / 100;
    final chroma = value * saturation.clamp(0, 1);
    final sector = (hue % 360) / 60;
    final x = chroma * (1 - (sector % 2 - 1).abs());
    final (r, g, b) = switch (sector.floor()) {
      0 => (chroma, x, 0.0),
      1 => (x, chroma, 0.0),
      2 => (0.0, chroma, x),
      3 => (0.0, x, chroma),
      4 => (x, 0.0, chroma),
      _ => (chroma, 0.0, x),
    };
    final m = value - chroma;
    int channel(double c) => ((c + m) * 255).round().clamp(0, 255);
    return (channel(r), channel(g), channel(b));
  }

  /// Data points to write for one frame on [config] in [mode].
  Map<int, Object> toDps(LightConfig config, SyncMode mode) {
    if (mode == SyncMode.color) {
      final String value;
      if (config.profile == DpProfile.legacy) {
        final (r, g, b) = rgb;
        value = tuya.BulbDevice.rgbToHexvalue(r, g, b, 'rgb8');
      } else {
        String hex(num n) => n.round().toRadixString(16).padLeft(4, '0');
        value =
            '${hex(hue.clamp(0, 359))}'
            '${hex(saturation.clamp(0, 1) * 1000)}'
            '${hex((brightness.clamp(0, 100) * 10).clamp(10, 1000))}';
      }
      return {config.colorDp!: value};
    }
    return {
      config.brightnessDp!: config.brightnessValue(brightness),
      if (config.temperatureDp != null)
        config.temperatureDp!:
            (temperature.clamp(0, 100) * config.valueMax / 100).round(),
    };
  }

  /// Data points that switch the bulb on and into the right mode.
  static Map<int, Object> startDps(LightConfig config, SyncMode mode) => {
    config.switchDp: true,
    if (config.modeDp != null)
      config.modeDp!: mode == SyncMode.color ? 'colour' : 'white',
  };
}

/// Turns captured frames into a rate-limited stream of [LightFrame]s. Rising
/// light reacts faster than falling light so the bulb "breathes" with the
/// picture instead of flickering.
class SyncEngine {
  SyncEngine({
    this.settings = const SyncSettings(),
    this.minInterval = const Duration(milliseconds: 200),
    this.keepAlive = const Duration(seconds: 8),
  });

  SyncSettings settings;
  final Duration minInterval, keepAlive;

  double? _r, _g, _b, _luma;
  Duration? _lastInput, _lastSent;
  LightFrame? _sent;

  LightFrame? get lastSent => _sent;

  void reset() {
    _r = _g = _b = _luma = null;
    _lastInput = _lastSent = null;
    _sent = null;
  }

  /// Feeds one captured frame. Returns the frame to send, or null when the
  /// light should not be updated yet. Pass [canSend] false while a previous
  /// update is still in flight so smoothing continues without sending.
  LightFrame? next(ScreenColor color, Duration now, {bool canSend = true}) {
    final dt = _lastInput == null
        ? null
        : (now - _lastInput!).inMicroseconds / 1e6;
    _lastInput = now;
    final attack = .03 + .45 * settings.smoothing.clamp(0, 1);
    double blend(double? previous, double target, double tau) {
      if (previous == null || dt == null) return target;
      final alpha = 1 - math.exp(-dt / tau);
      return previous + (target - previous) * alpha;
    }

    _r = blend(_r, color.red, attack);
    _g = blend(_g, color.green, attack);
    _b = blend(_b, color.blue, attack);
    final fading = _luma != null && color.luma < _luma!;
    _luma = blend(_luma, color.luma, fading ? attack * 2.5 : attack);

    if (!canSend) return null;
    final frame = _frame(_r!, _g!, _b!, _luma!);
    final sinceSent = _lastSent == null ? null : now - _lastSent!;
    if (sinceSent != null) {
      if (sinceSent < minInterval) return null;
      if (sinceSent < keepAlive && !_changed(_sent!, frame)) return null;
    }
    _sent = frame;
    _lastSent = now;
    return frame;
  }

  LightFrame _frame(double r, double g, double b, double luma) {
    final max = math.max(r, math.max(g, b));
    final min = math.min(r, math.min(g, b));
    final delta = max - min;
    var hue = 0.0;
    if (delta > 0) {
      if (max == r) {
        hue = 60 * (((g - b) / delta) % 6);
      } else if (max == g) {
        hue = 60 * ((b - r) / delta + 2);
      } else {
        hue = 60 * ((r - g) / delta + 4);
      }
    }
    final saturation = max <= 0 ? 0.0 : delta / max;
    final low = math.min(settings.minBrightness, settings.maxBrightness);
    final high = math.max(settings.minBrightness, settings.maxBrightness);
    // A gamma below 1 keeps dim scenes visible on the bulb.
    final brightness =
        low + (high - low) * math.pow(luma.clamp(0, 1), .6).toDouble();
    final warmth = r + b <= 0 ? 0.0 : (b - r) / (r + b);
    return LightFrame(
      hue: hue < 0 ? hue + 360 : hue,
      saturation: math.min(1, saturation * 1.25),
      brightness: brightness,
      temperature: (50 + 60 * warmth).clamp(0, 100).toDouble(),
    );
  }

  static bool _changed(LightFrame a, LightFrame b) {
    final hueDelta = (a.hue - b.hue).abs();
    final hueDistance = math.min(hueDelta, 360 - hueDelta);
    return (a.brightness - b.brightness).abs() >= 2 ||
        (a.temperature - b.temperature).abs() >= 3 ||
        (a.saturation - b.saturation).abs() >= .05 ||
        (math.max(a.saturation, b.saturation) > .15 && hueDistance >= 4);
  }
}
