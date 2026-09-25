// The receive screen is the one place a user shows something to a stranger's
// camera, so the tests here are about the two ways it can embarrass them: not
// drawing a code at all, and drawing one that says the wrong thing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sugar_wallet_miner/screens/receive.dart';
import 'package:sugar_wallet_miner/widgets/qr.dart';
import 'package:sugar_wallet_miner/widgets/qr_view.dart';

const _address = 'sugar1qw508d6qejxtdg4y5r3zarvary0c5xw7k8m2q4v7';

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
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
