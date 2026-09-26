/// SUGAR wallet generation and address handling, with no dependencies.
///
/// Used by the app to give every user their own Sugarchain wallet, on their own
/// device, from their own secure random source. The mining SDK only ever receives
/// the finished address — the key never leaves this package's caller.
library;

export 'src/sugar_wallet.dart'
    show
        SugarWallet,
        SugarNetwork,
        ECPoint,
        AddressCheck,
        Bech32Result,
        checkAddress,
        looksLikeSugarAddress,
        bech32Encode,
        bech32Decode,
        base58Check,
        base58CheckDecode,
        hash160Of,
        compressedPubkeyOf,
        multiplyG,
        multiplyPoint,
        pointAdd,
        decodePubkey,
        curveOrder,
        halfCurveOrder,
        toHex,
        fromHex;
export 'src/bip32.dart' show ExtKey, sugarBip44Path, sugarOfficialMobilePath;
export 'src/ecdsa.dart' show Signature, signHash, verifyHash;
export 'src/transaction.dart'
    show TxIn, TxOut, Transaction, Utxo, Spent, SendPlan, SendResult, signAll, sighashAll;
export 'src/bip39.dart' show Mnemonic;
export 'src/hmac.dart' show HmacSha512, Pbkdf2;
export 'src/phrase_wallet.dart' show PhraseWallet;
export 'src/ripemd160.dart' show Ripemd160;
export 'src/sha512.dart' show Sha512;
export 'src/sha256.dart' show Sha256;
