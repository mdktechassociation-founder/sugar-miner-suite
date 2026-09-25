/// Picks the real TCP Stratum client where sockets exist, and a refusing stub on
/// the web. A browser cannot open a raw TCP connection to a pool — that is what
/// the WebSocket bridge in `sugar-miner/` is for — so the web build has no client
/// at all and says so in one sentence instead of failing obscurely.
library;

export 'stratum_io.dart' if (dart.library.js_interop) 'stratum_unsupported.dart';
