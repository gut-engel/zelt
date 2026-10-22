import 'package:qr/qr.dart';
import 'package:test/test.dart';
import 'package:zelt_core/terminal_qr.dart';

void main() {
  test('terminal QR: half blocks reproduce the exact module matrix', () {
    const data = 'zelt-relay:203.0.113.7:47017/cb_AyisVUfjpAv9TDC10mMcstEyD5VT1aSGaU7D4Hps';
    final img = QrImage(QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.L));
    final n = img.moduleCount;
    final lines = (terminalQr(data, ansi: false).split('\n')..removeLast());
    const quiet = 2;
    expect(lines.length, ((n + 2 * quiet) / 2).ceil());
    for (var r = -quiet; r < n + quiet; r++) {
      final line = lines[(r + quiet) ~/ 2];
      expect(line.length, n + 2 * quiet);
      for (var c = -quiet; c < n + quiet; c++) {
        final ch = line[c + quiet];
        final top = r.isEven == (-quiet).isEven;
        final shown = top ? (ch == '█' || ch == '▀') : (ch == '█' || ch == '▄');
        final want = r >= 0 && c >= 0 && r < n && c < n && img.isDark(r, c);
        expect(shown, want, reason: 'module $r,$c');
      }
    }
  });

  test('terminal QR: ANSI mode wraps every line in black on white', () {
    final out = terminalQr('zelt-relay:1.2.3.4:1/x');
    for (final l in out.trimRight().split('\n')) {
      expect(l, startsWith('\x1b[30;47m'));
      expect(l, endsWith('\x1b[0m'));
    }
  });
}
