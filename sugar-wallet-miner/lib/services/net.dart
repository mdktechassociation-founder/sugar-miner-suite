/// One GET, on whichever platform this build is for.
///
/// The app reads two public APIs — the pool's stats and a price feed — and, since
/// it can spend what it holds, it writes to one: it hands a signed transaction to
/// the chain. On Android, iOS, Linux, macOS and Windows that is `dart:io`'s
/// [HttpClient]; a browser has no such class, so the web twin uses the browser's
/// own `fetch`.
///
/// [httpGet] is the whole of the reading, and [httpPostText] exists for one caller
/// and one call — `POST /esplora/tx`, whose body is a transaction the user signed
/// on this device. It is the only write in this app, and what travels in it is the
/// transaction itself, which is public the moment it is broadcast: it names inputs
/// and outputs and no one's name, address book or key.
///
/// The user agent is set on every request so an API operator can see who is asking
/// and block it if they want to. A client that hides that is a client that deserves
/// to be blocked.
library;

export 'net_io.dart' if (dart.library.js_interop) 'net_web.dart';
