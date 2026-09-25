/// Picks the real yespower bindings where a native library can be loaded, and a
/// refusing stub where it cannot (the web). The rest of the engine imports this
/// file and never asks which one it got: on a platform that cannot hash, the
/// isolate is never started, so the stub exists to keep the code compiling and to
/// explain itself if anything ever does call it.
library;

export 'yespower_ffi.dart' if (dart.library.js_interop) 'yespower_unsupported.dart';
