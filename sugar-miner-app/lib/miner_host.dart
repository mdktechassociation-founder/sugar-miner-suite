import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import 'background_service.dart';
import 'desktop_service.dart';

/// One interface for the two ways this app can host a miner: Android's foreground
/// service (and iOS's foreground hook), or a desktop isolate.
///
/// The UI talks to this and never asks which one it got. That matters for more
/// than tidiness: the Android path is the one that keeps hashing with the screen
/// off, and the desktop path stops when the window closes — a difference the
/// screens state in words (see [hostNote]) instead of leaving the user to guess.
class MinerHost {
  final DesktopMiningService? _desktop;

  MinerHost._(this._desktop);

  static bool get isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  /// True when this build hosts the miner itself rather than handing it to a
  /// platform service.
  bool get isLocal => _desktop != null;

  factory MinerHost.forThisPlatform() {
    if (isDesktop) return MinerHost._(DesktopMiningService());

    // The Android/iOS path needs the service configured before use; on desktop
    // there is no service and configuring one would be a call into a plugin that
    // is not there.
    configureBackgroundService();
    return MinerHost._(null);
  }

  Stream<Map<String, dynamic>> on(String type) {
    final desktop = _desktop;
    if (desktop != null) return desktop.on(type);
    // The plugin types its payload as nullable; a null payload is meaningless
    // here, so it is dropped rather than passed on as an empty event.
    return FlutterBackgroundService().on(type).where((e) => e != null).cast<Map<String, dynamic>>();
  }

  void invoke(String type, [Map<String, dynamic>? payload]) {
    final desktop = _desktop;
    if (desktop != null) {
      desktop.invoke(type, payload);
      return;
    }
    FlutterBackgroundService().invoke(type, payload);
  }

  Future<bool> isRunning() async {
    final desktop = _desktop;
    if (desktop != null) return desktop.isRunning;
    return FlutterBackgroundService().isRunning();
  }

  Future<void> start() async {
    final desktop = _desktop;
    if (desktop != null) {
      desktop.invoke('start');
      return;
    }
    await FlutterBackgroundService().startService();
  }

  /// One sentence for the screen, so the user is told how this build behaves
  /// rather than finding out by closing the window.
  static String get hostNote => isDesktop
      ? 'Mining runs while this window is open, and stops when you close it. There is '
          'no notification on desktop: the app itself is the indicator.'
      : 'Mining continues with the screen off, with a notification that stays visible '
          'until you stop it.';
}
