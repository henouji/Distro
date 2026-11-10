import 'package:flutter/material.dart';

import '../../../core/local_network.dart';
import '../light_schedule.dart';

const lightingWeekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String lightingTime(BuildContext context, int minute) =>
    TimeOfDay(hour: minute ~/ 60, minute: minute % 60).format(context);

class LightScheduleEditor extends StatefulWidget {
  const LightScheduleEditor({super.key, this.initial});
  final LightSchedule? initial;

  @override
  State<LightScheduleEditor> createState() => _LightScheduleEditorState();
}

class _LightScheduleEditorState extends State<LightScheduleEditor> {
  late bool _enabled;
  late Set<int> _days;
  late List<LightingPoint> _points;
  String? _error;

  @override
  void initState() {
    super.initState();
    _enabled = widget.initial?.enabled ?? true;
    _days = {
      ...widget.initial?.days ?? [1, 2, 3, 4, 5, 6, 7],
    };
    _points = [
      ...widget.initial?.points ??
          const [
            LightingPoint(minute: 420, brightness: 80, temperature: 70),
            LightingPoint(minute: 1260, brightness: 20, temperature: 10),
          ],
    ];
  }

  Future<void> _edit([int? index]) async {
    final initial = index == null ? null : _points[index];
    final point = await showDialog<LightingPoint>(
      context: context,
      builder: (_) => _PointEditor(initial: initial),
    );
    if (point == null || !mounted) return;
    setState(() {
      if (index == null) {
        _points.add(point);
      } else {
        _points[index] = point;
      }
      _points.sort((a, b) => a.minute.compareTo(b.minute));
      _error = null;
    });
  }

  void _save() {
    final schedule = LightSchedule(
      enabled: _enabled,
      days: _days.toList()..sort(),
      points: _points,
    );
    try {
      schedule.validate();
      Navigator.pop(context, schedule);
    } on HomeHubException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Lighting timeline'),
    scrollable: true,
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enable schedule'),
            value: _enabled,
            onChanged: (value) => setState(() => _enabled = value),
          ),
          Wrap(
            spacing: 6,
            children: [
              for (var day = 1; day <= 7; day++)
                FilterChip(
                  label: Text(lightingWeekdays[day - 1]),
                  selected: _days.contains(day),
                  onSelected: (selected) => setState(() {
                    if (selected) {
                      _days.add(day);
                    } else {
                      _days.remove(day);
                    }
                  }),
                ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Local device time. The light turns on at the first time, '
            'fades between points, then holds the last setting until midnight. '
            'No commands run before the first time or on unselected days.',
          ),
          for (var index = 0; index < _points.length; index++)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(lightingTime(context, _points[index].minute)),
              subtitle: Text(
                'Brightness ${_points[index].brightness.round()}% / '
                'Temperature ${_points[index].temperature.round()}%',
              ),
              onTap: () => _edit(index),
              trailing: IconButton(
                tooltip:
                    'Remove time ${lightingTime(context, _points[index].minute)}',
                onPressed: _points.length > 2
                    ? () => setState(() => _points.removeAt(index))
                    : null,
                icon: const Icon(Icons.delete_outline),
              ),
            ),
          TextButton.icon(
            onPressed: _edit,
            icon: const Icon(Icons.add),
            label: const Text('Add time'),
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save schedule')),
    ],
  );
}

class _PointEditor extends StatefulWidget {
  const _PointEditor({this.initial});
  final LightingPoint? initial;

  @override
  State<_PointEditor> createState() => _PointEditorState();
}

class _PointEditorState extends State<_PointEditor> {
  late int _minute;
  late double _brightness, _temperature;

  @override
  void initState() {
    super.initState();
    _minute = widget.initial?.minute ?? 720;
    _brightness = widget.initial?.brightness ?? 50;
    _temperature = widget.initial?.temperature ?? 50;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Lighting time'),
    scrollable: true,
    content: SizedBox(
      width: 300,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.schedule),
            label: Text(lightingTime(context, _minute)),
            onPressed: () async {
              final time = await showTimePicker(
                context: context,
                initialTime: TimeOfDay(
                  hour: _minute ~/ 60,
                  minute: _minute % 60,
                ),
              );
              if (time != null && mounted) {
                setState(() => _minute = time.hour * 60 + time.minute);
              }
            },
          ),
          Text('Brightness ${_brightness.round()}%'),
          Slider(
            value: _brightness,
            max: 100,
            semanticFormatterCallback: (value) =>
                '${value.round()} percent brightness',
            onChanged: (value) => setState(() => _brightness = value),
          ),
          Text('Temperature ${_temperature.round()}% (warm to cool)'),
          Slider(
            value: _temperature,
            max: 100,
            semanticFormatterCallback: (value) =>
                '${value.round()} percent from warm to cool',
            onChanged: (value) => setState(() => _temperature = value),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(
          context,
          LightingPoint(
            minute: _minute,
            brightness: _brightness,
            temperature: _temperature,
          ),
        ),
        child: const Text('Save time'),
      ),
    ],
  );
}
