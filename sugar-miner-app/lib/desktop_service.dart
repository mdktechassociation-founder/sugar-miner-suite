import 'dart:async';
import 'dart:isolate';

import 'miner_loop.dart';

/// The desktop's answer to Android's foreground service.
///
/// There is no service to ask for here — a desktop app is either open or it is
/// not, and that is already the whole story. So this runs the *same* mining loop
/// in an isolate, keeps the UI off the hashing path, and relays the same events
/// (`stats`, `log`, `share`) that the Android service relays.
///
/// What it deliberately does not pretend:
///
///   * there is no notification, because desktop Flutter has no equivalent that
///     this app ships — mining is visible through the app window, and it stops the
///     moment the window closes;
///   * there is no battery or thermal sensor to pause on, so the daily minute cap
///     and the CPU share are the limits that apply.
class DesktopMiningService {
  final Map<String, StreamController<Map<String, dynamic>>> _events = {};
  final StreamController<void> _stop = StreamController<void>.broadcast();
  final StreamController<void> _pause = StreamController<void>.broadcast();
  final StreamController<void> _resume = StreamController<void>.broadcast();
  Isolate? _isolate;
  SendPort? _toMiner;

  bool get isRunning => _isolate != null;

  /// The same shape as the Android service's `on(type)`, so the UI does not need
  /// to know which host it is talking to.
  Stream<Map<String, dynamic>> on(String type) =>
      (_events[type] ??= StreamController<Map<String, dynamic>>.broadcast()).stream;

  void invoke(String type, [Map<String, dynamic>? payload]) {
    switch (type) {
      case 'start':
        _spawn();
      case 'stop':
        _stop.add(null);
        _shutdown();
      case 'pause':
        _pause.add(null);
      case 'resume':
        _resume.add(null);
    }
  }

  Future<void> _spawn() async {
    if (_isolate != null) return;
    final ready = ReceivePort();
    _isolate = await Isolate.spawn(_entry, ready.sendPort, debugName: 'sugar-miner');

    final fromMiner = ReceivePort();
    _toMiner = await ready.first as SendPort;
    _toMiner!.send(fromMiner.sendPort);

    fromMiner.listen((message) {
      if (message is List && message.length == 2) {
        final type = message[0] as String;
        final data = Map<String, dynamic>.from(message[1] as Map);
        _events.putIfAbsent(type, () => StreamController<Map<String, dynamic>>.broadcast()).add(data);
      }
    });

    // The isolate keeps its own command ports; hand it the stop/pause/resume
    // streams as plain messages so a single send port is enough.
    _stop.stream.listen((_) => _toMiner?.send('stop'));
    _pause.stream.listen((_) => _toMiner?.send('pause'));
    _resume.stream.listen((_) => _toMiner?.send('resume'));
  }

  void _shutdown() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _toMiner = null;
  }

  static Future<void> _entry(SendPort ready) async {
    final commands = ReceivePort();
    ready.send(commands.sendPort);

    final stop = StreamController<void>.broadcast();
    final pause = StreamController<void>.broadcast();
    final resume = StreamController<void>.broadcast();
    commands.listen((m) {
      switch (m) {
        case 'stop':
          stop.add(null);
        case 'pause':
          pause.add(null);
        case 'resume':
          resume.add(null);
      }
    });

    await runMiningLoop(
      cb: MiningCallbacks(
        tell: (type, payload) => ready.send([type, payload]),
        // No system notification on the desktop: the window is the indicator,
        // and a host that wants more can show the events it already gets.
        notify: (_, __) {},
        log: (message) => ready.send(['log', {'message': message}]),
        wanted: () async => true, // the isolate is killed when the app closes
      ),
      stop: stop.stream,
      pause: pause.stream,
      resume: resume.stream,
    );
  }
}
