/// Asks the live chain API the two questions the send screen asks, and prints what
/// it answers. Read-only: it never signs and never broadcasts, so it is safe to run
/// against mainnet at any time.
///
///     dart run tool/chain_smoke.dart [address]
///
/// Without an argument it uses the key-1 address the wallet package's own vectors
/// are checked against. A CI run does not do this — the network is not a test
/// dependency — but a person releasing the app should.
library;

// ignore_for_file: avoid_print, avoid_relative_lib_imports
// A command-line tool talks by printing; that is what it is for.

import 'package:sugar_wallet/sugar_wallet.dart';

import '../lib/services/chain_api.dart';

Future<void> main(List<String> args) async {
  final address = args.isNotEmpty ? args.first : 'sugar1qw508d6qejxtdg4y5r3zarvary0c5xw7kjjlkp2';
  const api = ChainApi();

  print('the chain API: ${ChainApi.base}');
  print('address:       $address');
  print('script to spend it: ${ChainApi.scriptForAddress(address) ?? "(not a P2WPKH address)"}');

  for (final row in checkAddress(address)) {
    if (row.ok == false) print('  ! ${row.label}: ${row.note}');
  }

  final rate = await api.feeRatePerVByte();
  print('fee rate:      $rate sat/vB  (the API answers in sat/kB)');

  final utxos = await api.unspent(address);
  if (utxos.isEmpty) {
    print('unspent:       none — this address holds nothing spendable right now');
    return;
  }
  var total = 0;
  for (final u in utxos) {
    total += u.sats;
    print('unspent:       ${u.txid}:${u.vout}  ${u.sats} sat');
  }
  print('total:         $total sat — ${(total / 100000000).toStringAsFixed(8)} SUGAR');
  // What a one-input, two-output spend of the largest coin would cost at this rate.
  final vbytes = SendPlan.estimateVBytes(1, 2);
  print('a spend of it: $vbytes vB, fee ${(vbytes * rate)} sat at this rate');
}
