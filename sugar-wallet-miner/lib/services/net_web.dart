import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

@JS('fetch')
external JSPromise<JSAny?> _fetch(JSString url);

/// A plain GET through the browser's own fetch.
///
/// Two things are the same as the native path on purpose: the user agent, so an
/// API operator can tell who is calling, and GET-only, so this can never become an
/// upload. The browser may block a cross-origin read; when it does, the caller
/// shows a dash rather than a made-up number — the app is written to survive both
/// APIs being unreachable.
Future<String> httpGet(String url, {Duration timeout = const Duration(seconds: 15)}) async {
  final response = await _fetch(url.toJS).toDart.timeout(timeout);
  final obj = response as JSObject;
  final status = (obj.getProperty('status'.toJS) as JSNumber?)?.toDartInt ?? 0;
  final text = (obj.getProperty('text'.toJS) as JSFunction).callAsFunction() as JSPromise<JSString>;
  final body = (await text.toDart.timeout(timeout)).toDart;
  if (status != 200) throw StateError('HTTP $status');
  return body;
}
