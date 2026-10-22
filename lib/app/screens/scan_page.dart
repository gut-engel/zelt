import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Whether this platform has a camera QR scanner.
bool get canScanQr => Platform.isAndroid || Platform.isIOS;

/// Full-screen camera scanner. Pops with the first QR value that starts with
/// one of [prefixes].
class ScanPage extends StatefulWidget {
  final String title;
  final List<String> prefixes;
  const ScanPage({super.key, required this.title, required this.prefixes});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;
  String? _hint;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture cap) {
    if (_done) return;
    for (final b in cap.barcodes) {
      final v = b.rawValue;
      if (v == null) continue;
      if (widget.prefixes.any(v.startsWith)) {
        _done = true;
        Navigator.pop(context, v);
        return;
      }
      setState(() => _hint = 'That QR code is not a zelt code.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Stack(
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          if (_hint != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 32,
              child: Card(child: Padding(padding: const EdgeInsets.all(12), child: Text(_hint!))),
            ),
        ],
      ),
    );
  }
}
