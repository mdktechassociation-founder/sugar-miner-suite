/// One GET, on whichever platform this build is for.
///
/// The app reads two public APIs — the pool's stats and a price feed — and that is
/// the whole of its networking. On Android, iOS, Linux, macOS and Windows that is
/// `dart:io`'s [HttpClient]; a browser has no such class, so the web twin uses the
/// browser's own `fetch`. Both are GET-only, because the app has nothing to send:
/// there is no upload path in this repository, by design.
///
/// The user agent is set on every request so an API operator can see who is asking
/// and block it if they want to. A client that hides that is a client that deserves
/// to be blocked.
library;

export 'net_io.dart' if (dart.library.js_interop) 'net_web.dart';
