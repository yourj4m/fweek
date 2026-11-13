import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications_linux/flutter_local_notifications_linux.dart';

import '../ui/task_list.dart' show formatTime;
import 'reminders.dart';

/// What a reminder notification says: the task, then its time and note.
({String title, String body}) reminderText(DueReminder due, {required bool use24h}) {
  final task = due.task;
  final time = task.time == null ? null : formatTime(task.time!, use24h: use24h);
  final note = task.note.trim();
  return (
    title: task.title,
    body: [?time, if (note.isNotEmpty) note].join(' · '),
  );
}

/// A positive 31-bit number derived from [key] (FNV-1a), the same on every
/// run, for naming a reminder to the system.
int stableId(String key) {
  var hash = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

/// Notifications through the Linux desktop's notification service.
class DesktopNotifications {
  final _plugin = LinuxFlutterLocalNotificationsPlugin();
  Future<bool>? _ready;
  int _nextId = 0;

  void init() {
    _ready = _plugin
        .initialize(
          settings: const LinuxInitializationSettings(defaultActionName: 'Open'),
        )
        .then((ok) => ok ?? false)
        .catchError((Object error) {
      debugPrint('Notifications unavailable: $error');
      return false;
    });
  }

  Future<void> show({required String title, required String body}) async {
    if (await _ready != true) return;
    try {
      await _plugin.show(
        id: _nextId++,
        title: title,
        body: body,
        notificationDetails: const LinuxNotificationDetails(),
      );
    } on Object catch (error) {
      debugPrint('Could not show a notification: $error');
    }
  }
}
