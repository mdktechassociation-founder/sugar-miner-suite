import 'dart:convert';
import 'dart:io';

/// The name this app gives every API it talks to, so an operator can see
/// who is asking and block it if they want.
const _userAgent = 'sugar-wallet/1.0';

/// A plain GET, on any platform with a socket: Android, iOS and all three desktops.
Future<String> httpGet(String url, {Duration timeout = const Duration(seconds: 15)}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
    request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    final response = await request.close().timeout(timeout);
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
    }
    return body;
  } finally {
    client.close(force: true);
  }
}

/// One POST of an already-signed transaction, on any platform with a socket.
///
/// This exists for the broadcast endpoint and nothing else. The body is the raw
/// hex of a transaction this device signed; the server that receives it learns
/// what the whole world learns a second later anyway, when the transaction lands
/// in a block.
Future<String> httpPostText(String url, String body,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.postUrl(Uri.parse(url)).timeout(timeout);
    request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    request.headers.contentType = ContentType.text;
    request.write(body);
    final response = await request.close().timeout(timeout);
    final text = await response.transform(utf8.decoder).join().timeout(timeout);
    if (response.statusCode != 200) {
      // The node explains itself in the body — "bad-txns-inputs-missingorspent"
      // and friends — so it is carried out to the caller who can show it.
      throw HttpException(text.trim().isEmpty ? 'HTTP ${response.statusCode}' : text.trim(),
          uri: Uri.parse(url));
    }
    return text;
  } finally {
    client.close(force: true);
  }
}
