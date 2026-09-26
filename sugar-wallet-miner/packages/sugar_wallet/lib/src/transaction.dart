/// Building and signing a real Sugarchain transaction.
///
/// What this does, in order: pick unspent outputs, build the unsigned
/// transaction, compute each input's BIP-143 sighash, sign it with the key the
/// wallet already holds, and serialise the result into bytes a node will accept.
/// Nothing here touches a network — signing happens on the device, and the only
/// thing that ever leaves it is the finished transaction, which is public anyway.
///
/// The sighash is **BIP-143**, the segwit one. It exists because a legacy
/// signature commits to every input's script, which the signer may not have; the
/// segwit version commits to what it actually needs, and to the input's *value*,
/// which closes off a whole class of hardware-wallet attacks. Building a Sugarchain
/// transaction that spends a `sugar1q…` output means implementing it — and the
/// published vector in BIP-143 is what says whether the implementation is right.
library;

import 'dart:typed_data';

import 'ecdsa.dart';
import 'sha256.dart';
import 'sugar_wallet.dart';

const int sighashAll = 0x01;

/// A transaction input, before it is signed.
class TxIn {
  final String txid; // as displayed: big-endian hex, 64 characters
  final int vout;
  final int sequence;

  /// The unlocking script for a *legacy* (P2PKH) input, set by [signP2pkh].
  /// A segwit input leaves this empty and carries a witness instead; a legacy
  /// input is the other way round, and putting a signature in the wrong one of
  /// the two is a transaction that looks signed and is not.
  Uint8List? scriptSig;

  TxIn(this.txid, this.vout, {this.sequence = 0xffffffff});

  /// The 32 bytes as they appear on the wire: reversed from the displayed form.
  Uint8List get txidBytes {
    final forward = fromHex(txid);
    if (forward.length != 32) {
      throw ArgumentError('a txid is 32 bytes, got ${forward.length}');
    }
    return Uint8List.fromList(forward.reversed.toList());
  }
}

/// A transaction output: an amount in satoshis and a locking script.
class TxOut {
  final int sats;
  final Uint8List scriptPubKey;

  TxOut(this.sats, List<int> scriptPubKey)
      : scriptPubKey = Uint8List.fromList(scriptPubKey);

  /// P2WPKH — `OP_0 <20-byte hash160>`, what a `sugar1q…` address means.
  factory TxOut.p2wpkh(int sats, String address) {
    final decoded = bech32Decode(address);
    if (decoded == null || decoded.witver != 0 || decoded.program.length != 20) {
      throw ArgumentError('not a v0 bech32 address: $address');
    }
    return TxOut(sats, [0x00, 0x14, ...decoded.program]);
  }

  /// P2PKH — the legacy `S…` form.
  factory TxOut.p2pkh(int sats, String address) {
    final payload = base58CheckDecode(address);
    if (payload == null || payload.length != 21) {
      throw ArgumentError('not a base58 address: $address');
    }
    // OP_DUP OP_HASH160 <20 bytes> OP_EQUALVERIFY OP_CHECKSIG. The 0xa9 is
    // OP_HASH160 and it is not optional: without it the script is `OP_DUP <push>`
    // followed by two bytes nobody can execute, and the coins sent to it are
    // unspendable by anyone. A signed transaction that pays to such a script is
    // valid and accepted, which is exactly what makes the mistake expensive.
    return TxOut(sats, [0x76, 0xa9, 0x14, ...payload.sublist(1, 21), 0x88, 0xac]);
  }

  /// Whichever kind of address this is. Throws if it is neither — better to
  /// refuse than to build a transaction nobody can spend.
  factory TxOut.forAddress(int sats, String address, {SugarNetwork? network}) {
    final a = address.trim();
    if (bech32Decode(a) != null) return TxOut.p2wpkh(sats, a);
    final payload = base58CheckDecode(a);
    if (payload != null && payload.length == 21) {
      final net = network ?? SugarNetwork.mainnet;
      if (payload[0] != net.p2pkhPrefix) {
        throw ArgumentError(
            'that S… address belongs to another network (prefix 0x${payload[0].toRadixString(16)})');
      }
      return TxOut.p2pkh(sats, a);
    }
    throw ArgumentError('that is neither a sugar1q… nor an S… address: $address');
  }

  Uint8List serialize() {
    final out = BytesBuilder();
    out.add(_le64(sats));
    out.add(_varint(scriptPubKey.length));
    out.add(scriptPubKey);
    return out.toBytes();
  }
}

/// An unsigned transaction, and the machinery to sign it.
class Transaction {
  final int version;
  final List<TxIn> ins;
  final List<TxOut> outs;
  final int lockTime;

  /// Witness stack by input index. It is a *list of items*, because a P2WPKH
  /// witness is two of them — the signature and the public key — and the stack
  /// count is written as 2. Serialising the pair as one blob produces bytes that
  /// look plausible and that every node rejects.
  final Map<int, List<List<int>>> _witness = {};

  Transaction({
    required this.ins,
    required this.outs,
    this.version = 2,
    this.lockTime = 0,
  });

  /// BIP-143 sighash for input [index], which must spend a P2WPKH output of
  /// [amountSats] to the key whose hash160 is in [scriptCode].
  ///
  /// The structure, exactly as the BIP specifies it: a fixed frame with the
  /// outpoint, the input's value and sequence, and three double-SHA256
  /// commitments — to all outpoints, all sequences, and all outputs.
  Uint8List sighashP2wpkh(int index, int amountSats, Uint8List scriptCode) {
    final prevouts = BytesBuilder();
    for (final i in ins) {
      prevouts.add(i.txidBytes);
      prevouts.add(_le32(i.vout));
    }
    final sequences = BytesBuilder();
    for (final i in ins) {
      sequences.add(_le32(i.sequence));
    }
    final outputs = BytesBuilder();
    for (final o in outs) {
      outputs.add(o.serialize());
    }

    final preimage = BytesBuilder();
    preimage.add(_le32(version));
    preimage.add(_dsha(prevouts.toBytes()));
    preimage.add(_dsha(sequences.toBytes()));
    preimage.add(ins[index].txidBytes);
    preimage.add(_le32(ins[index].vout));
    preimage.add(_varint(scriptCode.length));
    preimage.add(scriptCode);
    preimage.add(_le64(amountSats));
    preimage.add(_le32(ins[index].sequence));
    preimage.add(_dsha(outputs.toBytes()));
    preimage.add(_le32(lockTime));
    preimage.add(_le32(sighashAll));
    return _dsha(preimage.toBytes());
  }

  /// The scriptCode for a P2WPKH input: the *legacy* P2PKH script of the same
  /// hash160. It looks wrong and is correct — BIP-143 says so.
  static Uint8List p2wpkhScriptCode(Uint8List hash160) =>
      Uint8List.fromList([0x76, 0xa9, 0x14, ...hash160, 0x88, 0xac]);

  /// The signature hash for a *legacy* P2PKH input — the pre-segwit rule, which
  /// every wallet on the chain understands.
  ///
  /// It is a different shape from BIP-143 and, unlike it, it does not commit to
  /// the amount being spent: the input's value is not in the preimage at all. That
  /// is the historical weakness segwit fixed, and it is also why this app defaults
  /// to segwit everywhere it can.
  ///
  ///   version | outpoint count | outpoints | script (scriptCode) | sequence
  ///   | output count | outputs | locktime | SIGHASH_ALL
  ///
  /// with every *other* input's script replaced by an empty one, and the input
  /// being signed carrying the script it is being unlocked with.
  Uint8List sighashP2pkh(int index, Uint8List scriptCode) {
    final preimage = BytesBuilder();
    preimage.add(_le32(version));
    preimage.add(_varint(ins.length));
    for (var i = 0; i < ins.length; i++) {
      preimage.add(ins[i].txidBytes);
      preimage.add(_le32(ins[i].vout));
      if (i == index) {
        preimage.add(_varint(scriptCode.length));
        preimage.add(scriptCode);
      } else {
        preimage.addByte(0x00); // an empty script for every other input
      }
      preimage.add(_le32(ins[i].sequence));
    }
    preimage.add(_varint(outs.length));
    for (final o in outs) {
      preimage.add(o.serialize());
    }
    preimage.add(_le32(lockTime));
    preimage.add(_le32(sighashAll));
    return _dsha(preimage.toBytes());
  }

  /// Signs a legacy P2PKH input. The result is `<sig> <pubkey>` in the input's
  /// scriptSig — the two pushes an `OP_DUP OP_HASH160 … OP_CHECKSIG` script
  /// expects to find underneath it.
  void signP2pkh(int index, Uint8List privateKey) {
    final pubkey = compressedPubkeyOf(privateKey);
    final digest = sighashP2pkh(index, p2pkhScriptCode(hash160Of(pubkey)));
    final signature = signHash(privateKey, digest);
    final sig = [...signature.toDer(), sighashAll];
    ins[index].scriptSig = Uint8List.fromList([
      ..._push(sig),
      ..._push(pubkey),
    ]);
  }

  /// The scriptCode for a P2PKH input: the script of the output being spent.
  static Uint8List p2pkhScriptCode(Uint8List hash160) =>
      Uint8List.fromList([0x76, 0xa9, 0x14, ...hash160, 0x88, 0xac]);

  /// Signs input [index] with a 32-byte key, given the value of the output it
  /// spends. The signature is stored for [serialize].
  void signP2wpkh(int index, Uint8List privateKey, int amountSats) {
    final pubkey = compressedPubkeyOf(privateKey);
    final hash160 = hash160Of(pubkey);
    final digest = sighashP2wpkh(index, amountSats, p2wpkhScriptCode(hash160));
    final signature = signHash(privateKey, digest);
    _witness[index] = [
      [...signature.toDer(), sighashAll], // the signature carries the hash type
      pubkey,
    ];
  }

  /// True once *every* input is signed, counting both kinds: a segwit input
  /// carries its signature in a witness, a legacy one in its scriptSig. A
  /// half-signed transaction must never be broadcast, and this is how the caller
  /// can tell.
  bool get isSigned => [
        for (var i = 0; i < ins.length; i++)
          _witness[i] != null || (ins[i].scriptSig?.isNotEmpty ?? false),
      ].every((signed) => signed);

  /// Bytes as broadcast: witness data included when anything is signed.
  Uint8List serialize({bool withWitness = true}) {
    final useWitness = withWitness && _witness.isNotEmpty;
    final out = BytesBuilder();
    out.add(_le32(version));
    if (useWitness) {
      out.addByte(0x00);
      out.addByte(0x01);
    }
    out.add(_varint(ins.length));
    for (var i = 0; i < ins.length; i++) {
      out.add(ins[i].txidBytes);
      out.add(_le32(ins[i].vout));
      // A segwit input's scriptSig is empty — its signature travels in the witness,
      // which is not covered by the txid and is not counted against the block
      // weight the same way. A legacy input is the other way round: the signature
      // is here, and there is no witness at all.
      final scriptSig = ins[i].scriptSig;
      if (scriptSig == null || scriptSig.isEmpty) {
        out.addByte(0x00);
      } else {
        out.add(_varint(scriptSig.length));
        out.add(scriptSig);
      }
      out.add(_le32(ins[i].sequence));
    }
    out.add(_varint(outs.length));
    for (final o in outs) {
      out.add(o.serialize());
    }
    if (useWitness) {
      for (var i = 0; i < ins.length; i++) {
        final items = _witness[i];
        if (items == null) {
          out.addByte(0x00); // an input with no witness at all
        } else {
          out.add(_varint(items.length));
          for (final item in items) {
            out.add(_varint(item.length));
            out.add(item);
          }
        }
      }
    }
    out.add(_le32(lockTime));
    return out.toBytes();
  }

  /// The transaction's identity, which for segwit is the hash of the *stripped*
  /// form — the witness is not part of it.
  String get txid {
    final stripped = serialize(withWitness: false);
    return toHex(_dsha(stripped).reversed.toList());
  }

  /// Virtual size in vbytes: witness bytes count a quarter, per BIP-141's rule.
  int get virtualSize {
    final full = serialize().length;
    final stripped = serialize(withWitness: false).length;
    return ((full - stripped) + 3) ~/ 4 + stripped;
  }
}

// ────────────────────────────────────────────────────────── preparation ──

/// An unspent output, as a block explorer reports it.
class Utxo {
  final String txid;
  final int vout;
  final int sats;

  /// True when this coin is a `sugar1q…` (P2WPKH) output, which is signed with
  /// BIP-143; false when it is a legacy `S…` (P2PKH) one, signed the old way.
  ///
  /// It defaults to true because that is what this app's own wallets receive and
  /// what the mining SDK is handed — but a WIF pasted in from Core or the web
  /// wallet usually comes with legacy coins attached, and they must be spent the
  /// way they were locked, not the way this app would prefer.
  final bool segwit;

  const Utxo({
    required this.txid,
    required this.vout,
    required this.sats,
    this.segwit = true,
  });
  String get key => '$txid:$vout';
}

class Spent {
  final Utxo utxo;
  final Uint8List privateKey;
  const Spent(this.utxo, this.privateKey);
}

class SendResult {
  final Transaction transaction;
  final int feeSats;
  final int changeSats;
  final String? changeAddress;

  /// The outputs this transaction spends, in input order. Each one's value is
  /// needed to sign it (BIP-143 signs over the amount), so it travels with the
  /// unsigned transaction rather than being looked up again — and looking it up
  /// again would be a chance to get it wrong.
  final List<Utxo> inputs;

  /// The size the fee was computed for, in virtual bytes.
  ///
  /// It is deliberately *not* the length of the unsigned transaction: an unsigned
  /// transaction has no signatures in it yet and is therefore smaller than the
  /// thing that gets broadcast. Showing that smaller number next to a fee derived
  /// from the larger one is how a wallet looks like it is overcharging.
  final int estimatedVBytes;

  /// One flag per input: true when that coin is a `sugar1q…` (P2WPKH) output and
  /// therefore signed with BIP-143, false when it is a legacy `S…` one and signed
  /// the old way. Empty means "treat every input as segwit".
  final List<bool> segwitInputs;

  const SendResult({
    required this.transaction,
    required this.inputs,
    required this.feeSats,
    required this.changeSats,
    required this.changeAddress,
    this.segwitInputs = const [],
    this.estimatedVBytes = 0,
  });

  String get rawHex => toHex(transaction.serialize());
  String get txid => transaction.txid;

  /// What the recipient gets. It is derived rather than stored, because the three
  /// numbers have to agree: inputs spent = amount + fee + change. If they ever
  /// stopped agreeing, this is where it would show.
  int get amountSats =>
      inputs.fold(0, (sum, u) => sum + u.sats) - feeSats - changeSats;

  /// Everything that leaves the wallet: the amount and the fee together.
  int get totalSpentSats => amountSats + feeSats;
}

/// The fee a transaction of this shape will cost, and the change it leaves.
///
/// The size is estimated from the known weights of the pieces (a P2WPKH input is
/// 68 vbytes, an output 31, the frame 11) rather than guessed from the amounts,
/// because the amount does not affect the size at all.
class SendPlan {
  static const int p2wpkhInputVBytes = 68;

  /// A legacy P2PKH input is 148 vB: the same 41-byte outpoint and sequence as a
  /// segwit input, plus a 107-byte scriptSig (a DER signature and a public key)
  /// against the 41-byte witness a P2WPKH input carries. Spending an `S…` coin
  /// costs more than twice what spending a `sugar1q…` coin costs, which is why the
  /// wallet asks for the segwit form wherever the caller gets a choice.
  static const int p2pkhInputVBytes = 148;
  static const int p2pkhOutputVBytes = 34;
  static const int p2wpkhOutputVBytes = 31;
  static const int frameVBytes = 11;

  /// 546 satoshis. Below this an output costs more to spend than it is worth,
  /// and nodes refuse to relay it — so change this small is added to the fee
  /// instead of being sent back.
  static const int dustSats = 546;

  /// [segwitInputs] of the inputs are P2WPKH and the rest are P2PKH; [p2pkhOutputs]
  /// of the outputs go to `S…` addresses and the rest to `sugar1q…` ones.
  static int estimateVBytes(int inputs, int outputs,
          {int segwitInputs = -1, int p2pkhOutputs = 0}) {
    final segwit = segwitInputs < 0 ? inputs : segwitInputs;
    final legacy = inputs - segwit;
    return frameVBytes +
        segwit * p2wpkhInputVBytes +
        legacy * p2pkhInputVBytes +
        (outputs - p2pkhOutputs) * p2wpkhOutputVBytes +
        p2pkhOutputs * p2pkhOutputVBytes;
  }

  /// Whether an address is a `sugar1q…` one, which is what the wallet prefers to
  /// send change to: it is smaller to receive and cheaper to spend later.
  static bool isSegwit(String address) => bech32Decode(address.trim()) != null;

  /// Chooses inputs for [amountSats] and builds the unsigned transaction.
  ///
  /// [feeRatePerVByte] comes from the network; it is a suggestion, and the user
  /// is shown the resulting fee before anything is signed.
  static SendResult prepare({
    required List<Spent> available,
    required int amountSats,
    required String toAddress,
    required String changeAddress,
    required num feeRatePerVByte,
    SugarNetwork? network,
    int extraOutputs = 0,

    /// Which of [available] are segwit coins (`sugar1q…`) and which are legacy
    /// (`S…`). Left alone when empty, everything is treated as segwit — the right
    /// assumption for the wallets this app makes for itself, and a wrong one that
    /// only ever overpays a fee by a few satoshis for anybody else.
    Map<String, bool> segwitByOutpoint = const {},
  }) {
    if (amountSats <= 0) throw ArgumentError('an amount must be positive');
    if (available.isEmpty) throw StateError('this wallet has no unspent outputs to spend');

    // Largest first: it keeps the input count down, and the input count is most
    // of what a fee is. It is not the theoretically optimal selection — a good
    // branch-and-bound would shave a few percent — but it is explainable, which
    // matters more when someone is deciding whether to trust a fee.
    final sorted = [...available]..sort((a, b) => b.utxo.sats.compareTo(a.utxo.sats));

    bool isSegwitCoin(Utxo u) => segwitByOutpoint[u.key] ?? true;

    final chosen = <Spent>[];
    var total = 0;
    for (final s in sorted) {
      chosen.add(s);
      total += s.utxo.sats;
      final vbytes = estimateVBytes(chosen.length, 1 + extraOutputs + 1,
          segwitInputs: chosen.where((c) => isSegwitCoin(c.utxo)).length,
          p2pkhOutputs: isSegwit(toAddress) ? 0 : 1);
      final fee = _feeFor(vbytes, feeRatePerVByte);
      if (total >= amountSats + fee) break;
    }

    final segwitInputs = chosen.where((c) => isSegwitCoin(c.utxo)).length;
    // The change goes back as segwit if this wallet can receive it there; an
    // address that is not a `sugar1q…` one cannot, and then the change output is
    // 3 bytes larger and is counted as such.
    final toIsSegwit = isSegwit(toAddress);
    final changeIsSegwit = isSegwit(changeAddress);
    int legacyOutputs() => (toIsSegwit ? 0 : 1) + (changeIsSegwit ? 0 : 1);

    final vbytesWithChange = estimateVBytes(chosen.length, 1 + extraOutputs + 1,
        segwitInputs: segwitInputs, p2pkhOutputs: legacyOutputs());
    var fee = _feeFor(vbytesWithChange, feeRatePerVByte);
    var change = total - amountSats - fee;
    var sizeForFee = vbytesWithChange;

    String? changeTo;
    final outs = <TxOut>[];
    if (change >= dustSats) {
      outs.add(TxOut.forAddress(amountSats, toAddress, network: network));
      outs.add(TxOut.forAddress(change, changeAddress, network: network));
      changeTo = changeAddress;
    } else {
      // No change worth returning: the size drops by one output, the fee drops
      // with it, and what is left over is added to the fee rather than burned as
      // a dust output nobody can spend.
      final vbytesNoChange = estimateVBytes(chosen.length, 1 + extraOutputs,
          segwitInputs: segwitInputs, p2pkhOutputs: toIsSegwit ? 0 : 1);
      final feeNoChange = _feeFor(vbytesNoChange, feeRatePerVByte);
      sizeForFee = vbytesNoChange;
      if (total < amountSats + feeNoChange) {
        throw StateError(
            'not enough to cover the amount and the fee: have ${total ~/ 100000000}.'
            '${(total % 100000000).toString().padLeft(8, '0')} SUGAR, '
            'need ${(amountSats + feeNoChange) ~/ 100000000}.'
            '${((amountSats + feeNoChange) % 100000000).toString().padLeft(8, '0')}');
      }
      outs.add(TxOut.forAddress(amountSats, toAddress, network: network));
      fee = total - amountSats; // the remainder is the fee
      change = 0;
      changeTo = null;
    }

    if (total < amountSats + fee) {
      throw StateError('the unspent outputs do not cover the amount and the fee');
    }

    return SendResult(
      transaction: Transaction(
        ins: [for (final s in chosen) TxIn(s.utxo.txid, s.utxo.vout)],
        outs: outs,
      ),
      inputs: [for (final s in chosen) s.utxo],
      segwitInputs: [for (final s in chosen) isSegwitCoin(s.utxo)],
      estimatedVBytes: sizeForFee,
      feeSats: fee,
      changeSats: change,
      changeAddress: changeTo,
    );
  }

  /// Rounds up: a fee that is one satoshi short is a transaction that sits in a
  /// mempool, and the difference is not worth the wait.
  static int _feeFor(int vbytes, num ratePerVByte) {
    final raw = vbytes * ratePerVByte;
    final fee = raw.ceil();
    return fee < 1 ? 1 : fee;
  }
}

/// Signs every input of a prepared transaction with the key for each outpoint.
///
/// [keyFor] must return the private key that owns a given UTXO, or null when the
/// wallet does not hold it. Refusing is the correct behaviour there: a transaction
/// with an input we cannot sign is a transaction that will be rejected.
Transaction signAll(SendResult prepared, Uint8List? Function(Utxo) keyFor) {
  final tx = prepared.transaction;
  if (prepared.inputs.length != tx.ins.length) {
    throw StateError('this plan is inconsistent: ${prepared.inputs.length} values '
        'for ${tx.ins.length} inputs');
  }
  for (var i = 0; i < tx.ins.length; i++) {
    final utxo = prepared.inputs[i];
    final key = keyFor(utxo);
    if (key == null) {
      throw StateError('no key for ${utxo.key}: this wallet cannot spend it');
    }
    if (prepared.segwitInputs.isEmpty || prepared.segwitInputs[i]) {
      tx.signP2wpkh(i, key, utxo.sats);
    } else {
      // A legacy coin: the signature goes in the scriptSig, and the amount is not
      // part of what is signed — see sighashP2pkh.
      tx.signP2pkh(i, key);
    }
  }
  if (!tx.isSigned) {
    throw StateError('a transaction was built with an unsigned input; refusing');
  }
  return tx;
}

// ───────────────────────────────────────────────────────── serialisation ──

Uint8List _le32(int v) =>
    Uint8List.fromList([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);

Uint8List _le64(int v) {
  final out = Uint8List(8);
  var x = v;
  for (var i = 0; i < 8; i++) {
    out[i] = x & 0xff;
    x >>= 8;
  }
  return out;
}

/// A minimal script push: a signature and a public key are both under 76 bytes,
/// so a single length byte is the whole of the encoding.
List<int> _push(List<int> data) {
  if (data.length > 75) {
    throw ArgumentError('this app only ever pushes short items, got ${data.length}');
  }
  return [data.length, ...data];
}

Uint8List _varint(int v) {
  if (v < 0xfd) return Uint8List.fromList([v]);
  if (v <= 0xffff) {
    return Uint8List.fromList([0xfd, v & 0xff, (v >> 8) & 0xff]);
  }
  if (v <= 0xffffffff) return Uint8List.fromList([0xfe, ..._le32(v)]);
  return Uint8List.fromList([0xff, ..._le64(v)]);
}

Uint8List _dsha(List<int> data) =>
    Uint8List.fromList(Sha256.digest(Sha256.digest(data)));
