/// The chain itself, read over the wallet's own public API.
///
/// Three calls, and the wallet can spend: what an address can spend right now,
/// what a transaction costs right now, and handing a signed transaction to the
/// network. The first two are `GET`s that carry a public address and nothing else.
/// The third carries a signed transaction — which is public by nature, because
/// that is what broadcasting means — and no key, no phrase, and no account: the
/// API has no idea who asked.
///
/// `api.sugar.wtf` is the same service the official SUGAR web wallet uses. It is
/// not ours, it holds nothing of the user's, and if it is unreachable the wallet
/// says so rather than guessing at a balance.
library;

import 'dart:convert';

import 'package:sugar_wallet/sugar_wallet.dart';

import 'net.dart';

/// How much more than the estimate the app is willing to pay when the node's own
/// answer is so low that a transaction might sit unconfirmed for a long time.
///
/// The node answers with a fixed estimate today (1 sat/vByte — see `/fee` in
/// `sugarchain-project/api-server`, which returns a constant and a TODO), so a
/// floor of 1 is what the chain actually asks for; the ceiling only guards against
/// a wildly wrong answer from a server that has been changed or replaced.
const int kMinFeeRatePerVByte = 1;
const int kMaxFeeRatePerVByte = 1000;

/// The scripts one address's coins can have. A `sugar1q…` address has only the
/// first; an `S…` address only the second.
class SpendScripts {
  final String? segwitScript;
  final String? legacyScript;
  const SpendScripts({this.segwitScript, this.legacyScript});
}

class ChainApi {
  /// The wallet's backend. One constant, in one place, so there is exactly one
  /// host to name when someone asks where this app talks to.
  static const String base = 'https://api.sugar.wtf';

  /// The one endpoint this app ever writes to: the chain's own broadcast route.
  /// It takes the raw hex of a signed transaction and nothing else.
  static const String broadcastPath = '/esplora/tx';

  final Duration timeout;

  /// The two calls, injectable so the parsing and the refusals can be tested
  /// without a network. In the app they are the platform's own GET and POST.
  final Future<String> Function(String url, {Duration timeout}) get;
  final Future<String> Function(String url, String body, {Duration timeout}) post;

  const ChainApi({
    this.timeout = const Duration(seconds: 30),
    this.get = httpGet,
    this.post = httpPostText,
  });

  /// The coins this address can spend, as the node sees them.
  ///
  /// The node's answer is `getaddressutxos`, so it is already the unspent ones —
  /// coins that were already spent cannot come back from here and be spent twice.
  /// What it cannot promise is that they are still unspent a second later, which
  /// is why a rejection at broadcast time is a normal outcome and not a bug.
  Future<List<Utxo>> unspent(String address) async {
    final result = await _get('/unspent/$address');
    if (result is! List) {
      throw const FormatException('the chain answered with something that is not a list');
    }
    final ours = scriptForAddress(address);
    final utxos = <Utxo>[];
    for (final row in result) {
      if (row is! Map) continue;
      final txid = row['txid'];
      final index = row['index'];
      final value = row['value'];
      final script = row['script'];
      if (txid is! String || index is! int || value is! int) continue;
      // The node said these coins belong to this address. When it also says what
      // the output's script is, that claim is checked: a wallet that signs whatever
      // an API hands it is a wallet that can be talked into signing something else.
      // When the field is absent the coin is kept — the address was still the one
      // asked about — but nothing is ever signed that this app did not build.
      final hex = script is String ? script.toLowerCase() : null;
      if (ours != null && hex != null && hex != ours.segwitScript &&
          hex != ours.legacyScript) {
        continue;
      }
      // Which of the two scripts it actually is decides how it gets signed later.
      // A guess here is a transaction that cannot be spent, so an unrecognised
      // script is treated as segwit only when it is the segwit one.
      final segwit = hex == null || hex != ours?.legacyScript;
      utxos.add(Utxo(txid: txid, vout: index, sats: value, segwit: segwit));
    }
    // Largest first, so a payment made of several coins settles on the fewest of
    // them and costs the fewest bytes in fees.
    utxos.sort((a, b) => b.sats.compareTo(a.sats));
    return utxos;
  }

  /// What the chain charges per virtual byte, right now, from its own estimate.
  ///
  /// The API answers in satoshis per kilobyte, which is what a node's fee
  /// estimator speaks; the app works in satoshis per virtual byte, which is what a
  /// transaction's size is measured in.
  ///
  /// The conversion rounds to the *nearest* whole satoshi per vByte, and that is a
  /// deliberate choice rather than laziness: the chain's own estimate today is
  /// 1001 sat/kB, which is a fractionally rounded 1 sat/vB, and rounding it up
  /// would double every fee this wallet pays for a 0.1% difference. Nearest keeps
  /// the ask at 1, and the fee arithmetic itself still rounds up (a transaction's
  /// fee is `ceil(vbytes × rate)`), so nothing is ever underpaid by the time it is
  /// signed.
  Future<int> feeRatePerVByte() async {
    final result = await _get('/fee');
    final perKb = (result is Map && result['feerate'] is num)
        ? (result['feerate'] as num).ceil()
        : 0;
    return vByteRateFromPerKb(perKb);
  }

  /// Satoshis per kilobyte as satoshis per virtual byte, to the nearest whole one,
  /// never below the floor and never above the ceiling.
  static int vByteRateFromPerKb(int perKb) {
    if (perKb <= 0) return kMinFeeRatePerVByte;
    final perVByte = (perKb + 500) ~/ 1000;
    return perVByte.clamp(kMinFeeRatePerVByte, kMaxFeeRatePerVByte);
  }

  /// Hand a signed transaction to the network and return its txid.
  ///
  /// The endpoint is the chain's own Esplora-compatible one: a raw hex body in,
  /// and either the txid or the node's complaint out. The complaint is passed
  /// through untouched — "bad-txns-inputs-missingorspent" is not a nice sentence
  /// but it is the true one, and a wallet that paraphrases it into "something went
  /// wrong" has taken away the only clue the user has.
  Future<String> broadcast(String rawHex) async {
    final hex = rawHex.trim();
    if (hex.isEmpty) throw const FormatException('nothing to broadcast');
    final answer = (await post('$base$broadcastPath', hex, timeout: timeout)).trim();
    if (answer.isEmpty) {
      throw const FormatException('the node answered with nothing at all');
    }
    // A success is a txid; anything else is a rejection, and a rejection must not
    // be mistaken for one. A 64-character hex string is the only shape a txid has.
    final looksLikeTxid = RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(answer);
    if (!looksLikeTxid) {
      throw FormatException(answer.split('\n').first.trim());
    }
    return answer.toLowerCase();
  }

  /// The two scripts this wallet can spend, as hex:
  ///
  ///  * P2WPKH — `OP_0` and the 20-byte public key hash, from a `sugar1q…` address
  ///  * P2PKH — `OP_DUP OP_HASH160 <20 bytes> OP_EQUALVERIFY OP_CHECKSIG`, from `S…`
  ///
  /// Anything else is refused rather than signed. A coin that is not locked to one
  /// of these two is not this wallet's to spend, whatever an API says.
  static SpendScripts? scriptForAddress(String address) {
    final bech = bech32Decode(address.trim());
    if (bech != null && bech.witver == 0 && bech.program.length == 20) {
      return SpendScripts(segwitScript: '0014${toHex(bech.program)}');
    }
    final payload = base58CheckDecode(address.trim());
    if (payload != null && payload.length == 21) {
      final h160 = toHex(payload.sublist(1, 21));
      return SpendScripts(legacyScript: '76a914${h160}88ac');
    }
    return null;
  }

  /// One read, decoded. The API wraps every answer in `{"result": …, "error": …}`,
  /// so the error is in the envelope and not only in the status code.
  Future<Object?> _get(String path) async {
    final body = await get('$base$path', timeout: timeout);
    final decoded = jsonDecode(body);
    if (decoded is Map && decoded['error'] != null) {
      final error = decoded['error'];
      throw FormatException(error is Map ? '${error['message'] ?? error}' : '$error');
    }
    return decoded is Map ? decoded['result'] : decoded;
  }
}
