import 'dart:js_interop';

import 'package:flutter/services.dart';

import 'web_font_metadata.dart';

@JS('window.crypto.subtle.digest')
external JSPromise<JSArrayBuffer> _digest(String algorithm, JSUint8Array data);

@JS('window.dispatchEvent')
external void _dispatchEvent(_StartupEvent event);

@JS('Event')
extension type _StartupEvent._(JSObject _) implements JSObject {
  external _StartupEvent(String type);
}

Future<void> loadAppFonts() async {
  final data = await rootBundle.load('assets/fonts/NotoSansSC.woff2');
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  if (bytes.length != webFontLength) {
    throw StateError('Unexpected font length');
  }
  final digest = (await _digest('SHA-256', bytes.toJS).toDart).toDart
      .asUint8List()
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  if (digest != webFontSha256) {
    throw StateError('Unexpected font content');
  }
  final loader = FontLoader('NotoSansSC')..addFont(Future.value(data));
  await loader.load();
}

void reportStartupFailure() {
  _dispatchEvent(_StartupEvent('simontalk-startup-error'));
}
