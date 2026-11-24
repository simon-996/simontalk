import 'dart:js_interop';

import 'realtime_transport.dart';

@JS('window.simontalkRealtime.supported')
external bool get _supported;

@JS('window.simontalkRealtimeFailed')
external bool? get _scriptFailed;

@JS('window.addEventListener')
external void _listen(String event, JSFunction listener);

@JS('window.removeEventListener')
external void _unlisten(String event, JSFunction listener);

@JS('window.simontalkRealtime.create')
external _BrowserTransport _create();

extension type _BrowserTransport._(JSObject _) implements JSObject {
  external JSPromise<JSString?> start(
    JSFunction exchangeOffer,
    JSFunction onObservation,
    JSFunction onEvent,
    JSFunction onCancel,
  );
  external JSPromise<JSString?> activate(String channelId);
  external JSString? send(String json, String channelId);
  external void setMuted(bool muted);
  external JSPromise<JSString?> resumePlayback();
  external JSString? holdPlayback();
  external JSPromise<JSString?> releasePlayback();
  external JSString? beginDrain();
  external void stop();
}

bool? get realtimeSupported {
  try {
    if (_scriptFailed == true) return false;
    return _supported;
  } catch (_) {
    return null;
  }
}

void Function() observeRealtimeSupport(void Function(bool) onReady) {
  final callback = ((JSAny? _) {
    final supported = realtimeSupported;
    if (supported != null) onReady(supported);
  }).toJS;
  _listen('simontalk-realtime-ready', callback);
  return () => _unlisten('simontalk-realtime-ready', callback);
}

RealtimeTransport createRealtimeTransport() => _WebRealtimeTransport();

class _WebRealtimeTransport implements RealtimeTransport {
  _BrowserTransport? _browser;
  bool _stopped = false;
  bool _started = false;

  _BrowserTransport get _transport {
    if (_stopped) throw const RealtimeFailure('cancelled');
    if (_browser case final browser?) return browser;
    final supported = realtimeSupported;
    if (supported != true) {
      throw RealtimeFailure(supported == null ? 'not_prepared' : 'unsupported');
    }
    return _browser = _create();
  }

  static void _check(JSString? result) {
    if (result != null) throw RealtimeFailure(result.toDart);
  }

  @override
  Future<void> start({
    required RealtimeSignaller signaller,
    required void Function(RealtimeObservation) onObservation,
    required void Function(RealtimeTransportEvent) onEvent,
  }) async {
    if (_started) throw const RealtimeFailure('already_started');
    final browser = _transport;
    _started = true;
    Future<JSString> exchange(JSString offer) async {
      try {
        return (await signaller.exchangeOffer(offer.toDart)).toJS;
      } catch (_) {
        throw const RealtimeFailure('signalling_failed');
      }
    }

    final result = await browser
        .start(
          ((JSString offer) => exchange(offer).toJS).toJS,
          ((JSString code, JSString detail) {
            onObservation(RealtimeObservation(code.toDart, detail.toDart));
          }).toJS,
          ((JSString json, JSString channelId) {
            onEvent(RealtimeTransportEvent(json.toDart, channelId.toDart));
          }).toJS,
          (() {
            _stopped = true;
            signaller.cancel();
          }).toJS,
        )
        .toDart;
    _check(result);
  }

  @override
  Future<void> activate(String channelId) async =>
      _check(await _transport.activate(channelId).toDart);

  @override
  void send(String json, String channelId) =>
      _check(_transport.send(json, channelId));

  @override
  void setMuted(bool muted) {
    if (!_stopped) _transport.setMuted(muted);
  }

  @override
  Future<void> resumePlayback() async =>
      _check(await _transport.resumePlayback().toDart);

  @override
  void holdPlayback() => _check(_transport.holdPlayback());

  @override
  Future<void> releasePlayback() async =>
      _check(await _transport.releasePlayback().toDart);

  @override
  void beginDrain() => _check(_transport.beginDrain());

  @override
  void stop() {
    _stopped = true;
    _browser?.stop();
  }
}
