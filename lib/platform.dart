import 'package:flutter/foundation.dart';

/// Whether the app runs on a phone or tablet: touch first, an on-screen
/// keyboard, system bars around the content, and a system that suspends the
/// app in the background. Follows [defaultTargetPlatform] so tests can set it.
bool get isMobile =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;
