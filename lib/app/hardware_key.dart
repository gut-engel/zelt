import 'dart:io';

import 'package:flutter/services.dart';
import 'package:zelt_core/vault.dart';

/// The vault's hardware key in the Android Keystore (see VaultKey.kt).
class AndroidKeystoreWrapper implements HardwareKeyWrapper {
  static const _channel = MethodChannel('zelt/service');
  @override
  final String kind;
  AndroidKeystoreWrapper._(this.kind);

  /// Null where there is no Android Keystore (desktop, tests).
  static Future<HardwareKeyWrapper?> open() async {
    if (!Platform.isAndroid) return null;
    final kind = await _channel.invokeMethod<String>('kinfo');
    return AndroidKeystoreWrapper._(kind ?? 'tee');
  }

  @override
  Future<Uint8List> wrap(Uint8List data) async =>
      (await _channel.invokeMethod<Uint8List>('kwrap', {'data': data}))!;

  @override
  Future<Uint8List> unwrap(Uint8List data) async =>
      (await _channel.invokeMethod<Uint8List>('kunwrap', {'data': data}))!;
}
