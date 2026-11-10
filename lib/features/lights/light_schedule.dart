import '../../core/local_network.dart';

class LightingPoint {
  const LightingPoint({
    required this.minute,
    required this.brightness,
    required this.temperature,
  });

  final int minute;
  final double brightness, temperature;

  Map<String, dynamic> toJson() => {
    'minute': minute,
    'brightness': brightness,
    'temperature': temperature,
  };

  factory LightingPoint.fromJson(Map<String, dynamic> json) => LightingPoint(
    minute: json['minute'] as int,
    brightness: (json['brightness'] as num).toDouble(),
    temperature: (json['temperature'] as num).toDouble(),
  );
}

class LightSchedule {
  const LightSchedule({
    this.enabled = true,
    required this.days,
    required this.points,
  });

  final bool enabled;
  final List<int> days;
  final List<LightingPoint> points;

  void validate() {
    bool percent(double value) => value.isFinite && value >= 0 && value <= 100;
    if (days.isEmpty ||
        days.any((day) => day < 1 || day > 7) ||
        days.toSet().length != days.length ||
        points.length < 2) {
      throw const HomeHubException(
        'Choose weekdays and at least two lighting times.',
      );
    }
    for (var index = 0; index < points.length; index++) {
      final point = points[index];
      if (point.minute < 0 ||
          point.minute >= 1440 ||
          !percent(point.brightness) ||
          !percent(point.temperature) ||
          (index > 0 && point.minute <= points[index - 1].minute)) {
        throw const HomeHubException(
          'Use distinct, increasing times and values from 0 to 100%.',
        );
      }
    }
  }

  LightingPoint? at(DateTime time) {
    if (!enabled || !days.contains(time.weekday)) return null;
    final minute = time.hour * 60 + time.minute + time.second / 60;
    if (minute < points.first.minute) return null;
    for (var index = 1; index < points.length; index++) {
      final end = points[index], start = points[index - 1];
      if (minute < end.minute) {
        final fraction = (minute - start.minute) / (end.minute - start.minute);
        return LightingPoint(
          minute: minute.floor(),
          brightness:
              start.brightness + (end.brightness - start.brightness) * fraction,
          temperature:
              start.temperature +
              (end.temperature - start.temperature) * fraction,
        );
      }
    }
    return points.last;
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'days': days,
    'points': points.map((point) => point.toJson()).toList(),
  };

  factory LightSchedule.fromJson(Map<String, dynamic> json) {
    final schedule = LightSchedule(
      enabled: json['enabled'] as bool,
      days: (json['days'] as List).cast<int>(),
      points: (json['points'] as List)
          .map(
            (point) =>
                LightingPoint.fromJson(Map<String, dynamic>.from(point as Map)),
          )
          .toList(),
    );
    schedule.validate();
    return schedule;
  }
}
