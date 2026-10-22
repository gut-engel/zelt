import 'package:qr/qr.dart';

/// Renders [data] as a QR code for a terminal: two modules per character
/// (Unicode half blocks), black on an explicit white background so it scans
/// on dark and light terminal themes alike, with a 2-module quiet zone.
String terminalQr(String data, {bool ansi = true}) {
  final code = QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.L);
  final img = QrImage(code);
  final n = code.moduleCount;
  const quiet = 2;
  bool dark(int r, int c) => r >= 0 && c >= 0 && r < n && c < n && img.isDark(r, c);
  final out = StringBuffer();
  for (var r = -quiet; r < n + quiet; r += 2) {
    if (ansi) out.write('\x1b[30;47m');
    for (var c = -quiet; c < n + quiet; c++) {
      final top = dark(r, c);
      final bottom = dark(r + 1, c);
      out.write(top && bottom ? '█' : top ? '▀' : bottom ? '▄' : ' ');
    }
    if (ansi) out.write('\x1b[0m');
    out.writeln();
  }
  return out.toString();
}

const qrBegin = '-----BEGIN ZELT RELAY QR-----';
const qrEnd = '-----END ZELT RELAY QR-----';
