import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications_linux/flutter_local_notifications_linux.dart';
import 'package:flutter_local_notifications_windows/flutter_local_notifications_windows.dart';

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

/// Notifications through the desktop's own service: the notification
/// service of the Linux desktop, or Windows' notification centre.
///
/// On Windows a notification is shown in the name of the app id the program
/// gives itself (see `windows/runner/main.cpp`), which the installer also
/// gives the Start-menu shortcut; Windows wants that shortcut before it
/// shows the notifications of an app that is not from the Store.
class DesktopNotifications {
  DesktopNotifications() : _windows = Platform.isWindows;

  final bool _windows;
  LinuxFlutterLocalNotificationsPlugin? _linux;
  FlutterLocalNotificationsWindows? _win;
  Future<bool>? _ready;
  int _nextId = 0;

  /// The app's id to Windows; the same in `windows/runner/main.cpp` and the
  /// installer.
  static const windowsAppId = 'yourj4m.fweek';

  /// Identifies the app's handler of clicks on its notifications to
  /// Windows. Fixed: a new one would be a different app to Windows.
  static const windowsGuid = 'e9933ada-534d-414e-a202-3e31d9136b48';

  void init() {
    final Future<bool?> started;
    if (_windows) {
      final plugin = _win = FlutterLocalNotificationsWindows();
      started = plugin.initialize(
        settings: const WindowsInitializationSettings(
          appName: 'fweek',
          appUserModelId: windowsAppId,
          guid: windowsGuid,
        ),
      );
    } else {
      final plugin = _linux = LinuxFlutterLocalNotificationsPlugin();
      started = plugin.initialize(
        settings: const LinuxInitializationSettings(defaultActionName: 'Open'),
      );
    }
    _ready = started.then((ok) => ok ?? false).catchError((Object error) {
      debugPrint('Notifications unavailable: $error');
      return false;
    });
  }

  Future<void> show({required String title, required String body}) async {
    if (await _ready != true) return;
    try {
      final id = _nextId++;
      if (_win case final plugin?) {
        await plugin.show(
          id: id,
          title: title,
          body: body,
          notificationDetails: const WindowsNotificationDetails(),
        );
      } else {
        await _linux?.show(
          id: id,
          title: title,
          body: body,
          notificationDetails: const LinuxNotificationDetails(),
        );
      }
    } on Object catch (error) {
      debugPrint('Could not show a notification: $error');
    }
  }
}
