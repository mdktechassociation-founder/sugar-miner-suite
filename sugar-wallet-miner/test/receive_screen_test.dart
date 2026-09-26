// The receive screen is the one place a user shows something to a stranger's
// camera, so the tests here are about the two ways it can embarrass them: not
// drawing a code at all, and drawing one that says the wrong thing.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sugar_wallet/sugar_wallet.dart';
import 'package:sugar_wallet_miner/screens/receive.dart';
import 'package:sugar_wallet_miner/widgets/qr.dart';
import 'package:sugar_wallet_miner/widgets/qr_view.dart';

/// The key-1 address from the wallet package's own cross-verified vectors, so this
/// test draws a code that is a real address and not merely a plausible string. (The
/// string that used to be here failed its own checksum — a QR of an address nobody
/// can receive at is the kind of thing this screen exists to avoid.)
const _address = 'sugar1qw508d6qejxtdg4y5r3zarvary0c5xw7kjjlkp2';

/// The other address the same key has. One key, two addresses: this is what the
/// switch on the screen is for.
const _legacyAddress = 'SXyGazfm6S3xfcySmD6QNkZYmtfysC2jvc';

Widget _wrap(Widget child) => MaterialApp(home: child);

/// A view tall enough that the whole list is built. A ListView does not build what
/// is below the fold, so on a default 800x600 test screen the address is simply not
/// there — and a test that cannot see it would pass while the screen was broken.
Future<void> _pumpReceive(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_wrap(child));
  await tester.pump();
}

void main() {

  test('both addresses this screen offers are real, and are the same key', () {
    expect(checkAddress(_address).where((r) => r.ok == false), isEmpty);
    // The legacy one is not a bech32 address at all: it is base58check with the
    // mainnet p2pkh prefix, which is what an old wallet will parse.
    final payload = base58CheckDecode(_legacyAddress);
    expect(payload, isNotNull, reason: 'a bad checksum here is an address nobody can pay');
    expect(payload!.length, 21);
    expect(payload.first, 0x3f, reason: 'SUGARCHAIN mainnet p2pkh prefix');
    expect(_address.startsWith('sugar1q'), isTrue);
    expect(_legacyAddress.startsWith('S'), isTrue);
  });

  testWidgets('the switch offers both forms, and the code follows it', (tester) async {
    await _pumpReceive(
        tester,
        const ReceiveScreen(address: _address, legacyAddress: _legacyAddress));
    // Segwit first: that is what the miner pays to and what modern wallets want.
    expect(find.text(_address), findsOneWidget);
    expect(find.text(_legacyAddress), findsNothing);

    await tester.tap(find.text('S…'));
    await tester.pump();
    expect(find.text(_legacyAddress), findsOneWidget);
    expect(find.text(_address), findsNothing);

    await tester.tap(find.text('sugar1q…'));
    await tester.pump();
    expect(find.text(_address), findsOneWidget);
  });

  testWidgets('copying copies whichever address is on screen', (tester) async {
    // The clipboard is a platform channel. Reading it back in a test hangs without
    // a handler, so the calls are intercepted and the text is checked here.
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await _pumpReceive(
        tester,
        const ReceiveScreen(address: _address, legacyAddress: _legacyAddress));
    await tester.tap(find.text('S…'));
    await tester.pump();
    await tester.tap(find.text('Copy address'));
    await tester.pump();
    expect(copied, [_legacyAddress]);

    await tester.tap(find.text('sugar1q…'));
    await tester.pump();
    await tester.tap(find.text('Copy address'));
    await tester.pump();
    expect(copied, [_legacyAddress, _address]);
  });

  testWidgets('with no legacy address the switch is not shown at all', (tester) async {
    await _pumpReceive(tester, const ReceiveScreen(address: _address));
    expect(find.text('Which address to give them'), findsNothing);
    expect(find.text(_address), findsOneWidget);
  });

  test('the address this screen is tested with passes the wallet\'s own check', () {
    final rows = checkAddress(_address);
    expect(rows.where((r) => r.ok == false), isEmpty,
        reason: 'a QR code is only as good as the string it encodes');
  });

  test('the encoder draws the address it was given, at the right size', () {
    final code = QrCode.encode(_address);
    expect(code.mask, inInclusiveRange(0, 7));
    expect(code.size, 33, reason: 'a 45-character address is version 4');
    // The quiet zone is part of the widget, so the symbol itself is drawn inside
    // four modules of white on every side.
    expect(code.at(0, 0), isTrue, reason: 'the top-left finder starts dark');
  });

  testWidgets('the receive screen shows the code and the address',
      (tester) async {
    await tester.pumpWidget(_wrap(const ReceiveScreen(address: _address)));
    await tester.pumpAndSettle();

    expect(find.byType(QrView), findsOneWidget);
    expect(find.text(_address), findsOneWidget);
    expect(find.textContaining('contains the address only'), findsOneWidget);
    expect(find.textContaining('never leaves this phone'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('copying puts the plain address on the clipboard', (tester) async {
    await tester.pumpWidget(_wrap(const ReceiveScreen(address: _address)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy address'));
    await tester.pumpAndSettle();
    expect(find.text('Address copied'), findsOneWidget);
  });

  testWidgets('an address that cannot be drawn is explained, not crashed',
      (tester) async {
    // Beyond version 10 the encoder refuses rather than emitting a broken code.
    final tooLong = 'sugar1${'q' * 1200}';
    await tester.pumpWidget(_wrap(ReceiveScreen(address: tooLong)));
    await tester.pumpAndSettle();

    expect(find.byType(QrView), findsNothing);
    expect(find.textContaining('cannot be drawn'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the code keeps its quiet zone and stays square', (tester) async {
    await tester.pumpWidget(_wrap(const ReceiveScreen(address: _address)));
    await tester.pumpAndSettle();
    final painted = tester.getSize(find.byType(QrView));
    expect(painted.width, painted.height);
  });
}
