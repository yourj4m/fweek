import 'package:flutter/services.dart';

/// A reminder handed to Android's alarm service.
class ScheduledReminder {
  const ScheduledReminder({
    required this.id,
    required this.at,
    required this.title,
    required this.body,
    required this.taskId,
  });

  /// Identifies the alarm and its notification; stable for the same task,
  /// moment and text, so re-sending an unchanged list changes nothing.
  final int id;
  final DateTime at;
  final String title;
  final String body;
  final String taskId;

  Map<String, Object?> toMap() => {
        'id': id,
        'at': at.millisecondsSinceEpoch,
        'title': title,
        'body': body,
        'task': taskId,
      };
}

/// The few things the app asks Android for directly; see MainActivity.kt.
class AndroidBridge {
  AndroidBridge() {
    _channel.setMethodCallHandler(_onCall);
  }

  static const _channel = MethodChannel('weektodo/platform');

  /// Called when a reminder notification is tapped while the app is running.
  void Function(String taskId)? onOpenTask;

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method == 'openTask' && call.arguments is String) {
      onOpenTask?.call(call.arguments as String);
    }
    return null;
  }

  /// Replaces the reminders the system holds with [reminders].
  Future<void> syncReminders(List<ScheduledReminder> reminders) =>
      _channel.invokeMethod<void>('syncReminders', {
        'reminders': [for (final r in reminders) r.toMap()],
      });

  Future<bool> notificationsAllowed() async =>
      await _channel.invokeMethod<bool>('notificationsAllowed') ?? false;

  /// Shows the system's permission prompt if it may still be shown.
  Future<bool> requestNotifications() async =>
      await _channel.invokeMethod<bool>('requestNotifications') ?? false;

  Future<void> openNotificationSettings() =>
      _channel.invokeMethod<void>('openNotificationSettings');

  /// The task whose reminder notification started the app, once.
  Future<String?> takeLaunchTask() =>
      _channel.invokeMethod<String>('takeLaunchTask');

  /// Asks where to save and writes [bytes] there. False when cancelled.
  Future<bool> saveDocument({
    required String name,
    required String mime,
    required Uint8List bytes,
  }) async =>
      await _channel.invokeMethod<bool>('saveDocument', {
        'name': name,
        'mime': mime,
        'bytes': bytes,
      }) ??
      false;
}
