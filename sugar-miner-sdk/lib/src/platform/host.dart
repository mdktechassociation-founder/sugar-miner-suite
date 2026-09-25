/// What this build is running on, and what that means for mining.
///
/// The engine is the same everywhere; how it is kept alive is not. Android has a
/// foreground service and a notification that must stay visible. A desktop keeps
/// the process running for as long as the app is open, and needs no permission
/// for anything. iOS suspends background work, so mining there only happens while
/// the app is on screen. A browser cannot open a raw TCP socket to a pool, and has
/// no native library to hash with, so web builds show a wallet and no miner.
///
/// Everything that differs between them is decided here, in one file, in words,
/// so no other part of the SDK has to guess.
library;

import 'package:flutter/foundation.dart';

import 'host_io.dart' if (dart.library.js_interop) 'host_web.dart' as impl;

class Host {
  const Host._();

  static bool get isWeb => kIsWeb;
  static bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static bool get isIOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  static bool get isMacOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
  static bool get isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  static bool get isLinux =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;
  static bool get isDesktop => isMacOS || isWindows || isLinux;

  /// A short name for screens and logs.
  static String get label {
    if (isWeb) return 'web';
    if (isAndroid) return 'android';
    if (isIOS) return 'ios';
    if (isMacOS) return 'macos';
    if (isWindows) return 'windows';
    if (isLinux) return 'linux';
    return 'unknown';
  }

  /// Whether hashing can happen here at all.
  ///
  /// False on the web, and that is not a limitation of this SDK: a browser cannot
  /// reach a pool's TCP port, and the whole engine is built on a native library
  /// that a browser has no way to load. The wallet still works there.
  static bool get canMine => !isWeb;

  /// Whether mining continues when the app is not the thing on screen.
  ///
  /// Android: yes, through the foreground service and its notification.
  /// Desktop: yes, for as long as the app is open — closing it stops mining.
  /// iOS: no. iOS suspends a backgrounded app, and no notification can hold it
  /// awake the way Android's foreground service does. Mining there is a
  /// foreground activity, and the UI says so rather than pretending.
  static bool get minesInBackground => isAndroid || isDesktop;

  /// Whether there is a system notification to keep visible.
  static bool get hasSystemNotification => isAndroid;

  /// Whether the platform needs a battery-optimisation exemption for this to run
  /// for hours. Only Android has that concept; asking for it elsewhere would be a
  /// permission request with no purpose.
  static bool get needsBatteryExemption => isAndroid;

  /// Cores to plan the worker around. The auto-configurator uses this instead of
  /// asking `dart:io` itself, so it compiles for the web too.
  static int get cpuCores => impl.cpuCores();

  /// Total memory in MB, or -1 when the platform does not say (anything that is
  /// not Linux). Only ever used to work *more gently*, so "unknown" is read as
  /// "not a small machine" by the caller — never as a reason to run harder.
  static int get ramMb => impl.ramMb();

  /// One sentence a host app can show a user about this platform, in the same
  /// voice as the rest of the SDK: no optimism, no hedging.
  static String get supportNote {
    if (isWeb) {
      return 'This is the web build: your wallet works here, mining does not. '
          'A browser cannot reach a mining pool directly, so nothing is hashed.';
    }
    if (isAndroid) {
      return 'Mining continues with the screen off, with a notification that stays '
          'visible until you stop it.';
    }
    if (isIOS) {
      return 'On iOS, mining runs only while this app is on screen. iOS suspends '
          'background apps, and no notification can hold them awake.';
    }
    return 'Mining runs while this app is open, and stops when you close it.';
  }
}
