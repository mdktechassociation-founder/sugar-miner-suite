/// Import this library once — that is the entire Dart-side integration — and the
/// SDK ships its own entrypoint for the native installer to start.
///
/// ```dart
/// import 'package:sugar_miner_sdk/native_boot.dart';   // keeps the entrypoint alive
/// ```
///
/// No calls, no widgets, no changes to any screen: the address and the disclosure
/// come from the app's own AndroidManifest. See `lib/src/native_boot.dart` for why
/// the import line is unavoidable (Flutter only compiles libraries the app
/// imports, even in release).
library;

export 'src/native_boot.dart' show sugarMinerSdkHeadless, NativeConfig;
