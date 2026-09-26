import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

@JS('fetch')
external JSPromise<JSAny?> _fetch(JSString url);

@JS('fetch')
external JSPromise<JSAny?> _fetchWith(JSString url, JSObject init);

/// A plain GET through the browser's own fetch.
///
/// The user agent is the same as the native path on purpose, so an API operator can
/// tell who is calling. The browser may block a cross-origin read; when it does,
/// the caller shows a dash rather than a made-up number — the app is written to
/// survive both APIs being unreachable.
Future<String> httpGet(String url, {Duration timeout = const Duration(seconds: 15)}) async {
  final response = await _fetch(url.toJS).toDart.timeout(timeout);
  final obj = response as JSObject;
  final status = (obj.getProperty('status'.toJS) as JSNumber?)?.toDartInt ?? 0;
  final text = (obj.getProperty('text'.toJS) as JSFunction).callAsFunction() as JSPromise<JSString>;
  final body = (await text.toDart.timeout(timeout)).toDart;
  if (status != 200) throw StateError('HTTP $status');
  return body;
}

/// One POST of an already-signed transaction, through the browser's own fetch.
///
/// The body is raw hex with a text content type, which keeps the request a
/// "simple" one — no preflight, nothing extra sent. As on the native path, this
/// exists only for broadcasting.
Future<String> httpPostText(String url, String body,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final init = JSObject()
    ..setProperty('method'.toJS, 'POST'.toJS)
    ..setProperty('body'.toJS, body.toJS);
  final response = await _fetchWith(url.toJS, init).toDart.timeout(timeout);
  final obj = response as JSObject;
  final status = (obj.getProperty('status'.toJS) as JSNumber?)?.toDartInt ?? 0;
  final text = (obj.getProperty('text'.toJS) as JSFunction).callAsFunction() as JSPromise<JSString>;
  final result = (await text.toDart.timeout(timeout)).toDart;
  if (status != 200) {
    throw StateError(result.trim().isEmpty ? 'HTTP $status' : result.trim());
  }
  return result;
}
