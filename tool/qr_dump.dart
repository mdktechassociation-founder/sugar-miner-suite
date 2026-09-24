import 'dart:io';
import 'package:sugar_wallet_miner/widgets/qr.dart';

void main(List<String> args) {
  final text = args.isNotEmpty ? args[0] : 'sugar1qw508d6qejxtdg4y5r3zarvary0c5xw7kjjlkp2';
  final mask = args.length > 1 ? int.parse(args[1]) : null;
  final qr = QrCode.encode(text, forceMask: mask);
  final sb = StringBuffer()..writeln('size: ${qr.size}\nmask: ${qr.mask}');
  for (var y = 0; y < qr.size; y++) {
    for (var x = 0; x < qr.size; x++) {
      sb.write(qr.at(x, y) ? '1' : '0');
    }
    sb.writeln();
  }
  File('/tmp/qr.txt').writeAsStringSync(sb.toString());
  stdout.writeln('size ${qr.size}, mask ${qr.mask}');
}
