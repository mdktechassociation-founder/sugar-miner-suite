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
        toHex,
        fromHex;
export 'src/ripemd160.dart' show Ripemd160;
export 'src/sha256.dart' show Sha256;
