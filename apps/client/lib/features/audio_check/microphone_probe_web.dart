import 'dart:js_interop';

import 'microphone_probe.dart';

@JS('window.simontalkMicrophone.supported')
external bool get _supported;

@JS('window.simontalkMicrophoneFailed')
external bool? get _scriptFailed;

@JS('window.addEventListener')
external void _listen(String event, JSFunction listener);

@JS('window.removeEventListener')
external void _unlisten(String event, JSFunction listener);

@JS('window.simontalkMicrophone.create')
external _BrowserProbe _create();

extension type _BrowserProbe._(JSObject _) implements JSObject {
  external JSPromise<JSString?> start(
    JSFunction onLevel,
    JSFunction onInterrupted,
  );
  external void stop();
}

bool? get microphoneSupported {
  try {
    if (_scriptFailed == true) return false;
    return _supported;
  } catch (_) {
    return null;
  }
}

void Function() observeMicrophoneSupport(void Function(bool) onReady) {
  final callback = ((JSAny? _) {
    final supported = microphoneSupported;
    if (supported != null) onReady(supported);
  }).toJS;
  _listen('simontalk-microphone-ready', callback);
  return () => _unlisten('simontalk-microphone-ready', callback);
}

MicrophoneProbe createMicrophoneProbe() => _WebMicrophoneProbe(_create());

class _WebMicrophoneProbe implements MicrophoneProbe {
  _WebMicrophoneProbe(this.browser);
  final _BrowserProbe browser;

  @override
  Future<void> start({
    required void Function(double) onLevel,
    required void Function(String) onInterrupted,
  }) async {
    final result = await browser.start(onLevel.toJS, onInterrupted.toJS).toDart;
    if (result != null) throw MicrophoneFailure(result.toDart);
  }

  @override
  void stop() => browser.stop();
}
