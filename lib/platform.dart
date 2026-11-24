import 'package:flutter/foundation.dart';

/// Whether the app runs on a phone or tablet: touch first, an on-screen
/// keyboard, system bars around the content, and a system that suspends the
/// app in the background. Follows [defaultTargetPlatform] so tests can set it.
bool get isMobile =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// Whether the app runs on Windows. Follows [defaultTargetPlatform] so tests
/// can set it.
bool get isWindows => defaultTargetPlatform == TargetPlatform.windows;

/// Where saved passwords and secret addresses are kept, for the sentence
/// "… is kept [secretPlace]".
String get secretPlace => isMobile
    ? 'encrypted on this device'
    : isWindows
        ? 'encrypted with your Windows login'
        : 'in the system keyring';
