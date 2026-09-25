import 'dart:convert';
import 'dart:io';

/// A plain GET, on any platform with a socket: Android, iOS and all three desktops.
Future<String> httpGet(String url, {Duration timeout = const Duration(seconds: 15)}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
    request.headers.set(HttpHeaders.userAgentHeader, 'sugar-wallet/1.0');
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
