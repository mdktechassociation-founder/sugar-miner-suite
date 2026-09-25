/// The parts of [Host] that need `dart:io`. Kept in its own file so the web build
/// can compile against a twin that has no filesystem at all.
library;

import 'dart:io';

int cpuCores() {
  try {
    return Platform.numberOfProcessors;
  } catch (_) {
    return 4;
  }
}

/// Total physical memory in MB, or -1 when it cannot be read (Windows and iOS
/// have no `/proc`, and this SDK does not want another plugin just to learn a
/// number it only uses to be *gentler* on small machines).
int ramMb() {
  try {
    final line = File('/proc/meminfo').readAsLinesSync().firstWhere(
          (l) => l.startsWith('MemTotal:'),
          orElse: () => '',
        );
    final kb = int.tryParse(RegExp(r'\d+').firstMatch(line)?.group(0) ?? '') ?? 0;
    return kb ~/ 1024;
  } catch (_) {
    return -1;
  }
}
