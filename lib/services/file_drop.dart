import 'package:flutter/services.dart';

/// Files dropped onto the window from a file manager (desktop). The
/// program's own window code tells their paths over this channel; see
/// `linux/runner/my_application.cc`.
abstract final class FileDrop {
  static const _channel = MethodChannel('weektodo/drop');

  /// Calls [onFiles] with the paths of dropped files from now on; null
  /// stops listening.
  static void listen(void Function(List<String> paths)? onFiles) {
    _channel.setMethodCallHandler(onFiles == null
        ? null
        : (call) async {
            final paths = call.arguments;
            if (call.method != 'files' || paths is! List) return;
            onFiles([...paths.whereType<String>()]);
          });
  }
}
