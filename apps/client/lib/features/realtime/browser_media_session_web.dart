import 'dart:async';
import 'dart:js_interop';

import '../../core/api_client.dart';
import '../practice/practice_models.dart';
import 'browser_media_session.dart';
import 'realtime_transport.dart';

@JS('window.simontalkBrowserMedia.open')
external _MediaSocket _open(
  String path,
  JSFunction consumeProof,
  JSFunction isCurrent,
  JSFunction onEvent,
  JSFunction closed,
);

extension type _MediaSocket._(JSObject _) implements JSObject {
  external void stop();
  external bool setMuted(bool value);
  external bool requestSlowPace();
  external bool interruptPlayback();
  external bool holdPlayback();
  external bool beginDrain();
}

RealtimeMediaSession createBrowserMediaSession({
  required ApiClient accountApi,
  required String accountId,
  required ConnectionReservation connection,
  required void Function(String kind, String payload) onEvent,
  required void Function(String reason) onClosed,
}) => BrowserMediaSession(
  api: accountApi,
  accountId: accountId,
  connection: connection,
  onEvent: onEvent,
  onClosed: onClosed,
);

/// One explicitly started browser connection to a same-origin media gateway.
class BrowserMediaSession implements RealtimeMediaSession {
  BrowserMediaSession({
    required this.api,
    required this.accountId,
    required this.connection,
    required this.onEvent,
    required this.onClosed,
  });

  final ApiClient api;
  final String accountId;
  final ConnectionReservation connection;
  final void Function(String kind, String payload) onEvent;
  final void Function(String reason) onClosed;
  final _active = Completer<void>();
  _MediaSocket? _socket;
  void Function()? _unlisten;
  bool _muted = false;
  bool _slowPaceRequested = false;
  bool _interruptRequested = false;
  bool _draining = false;
  bool _started = false;
  bool _closed = false;

  bool get _current => !_closed && api.hasCurrentAccount(accountId);

  /// Completes once capture is running and the initial mode has been sent.
  @override
  Future<void> start() {
    if (_started || _closed) throw const RealtimeFailure('already_closed');
    _started = true;
    _unlisten = api.observeIdentity(() {
      if (!_current) _finish('account_changed');
    });
    unawaited(_connect());
    return _active.future;
  }

  Future<void> _connect() async {
    try {
      if (api.baseUrl.origin != Uri.base.origin ||
          connection.status != ConnectionStatus.preparing) {
        throw const RealtimeFailure('media_unavailable');
      }
      final proof = await api.prepareWebSocketAuth(
        accountId: accountId,
        stillCurrent: () => _current,
      );
      if (!_current) {
        _finish('account_changed');
        return;
      }
      final path =
          '/v1/practice-sessions/${connection.sessionId}/connections/'
          '${connection.id}/media/${connection.clientInstanceId}/${connection.epoch}';
      onEvent('opening', '');
      if (!_current) {
        _finish('account_changed');
        return;
      }
      _socket = _open(
        path,
        (() => proof.consume()).toJS,
        (() => _current).toJS,
        ((String kind, String payload) {
          if (!_current) return;
          if (kind == 'active' && !_active.isCompleted) _active.complete();
          onEvent(kind, payload);
        }).toJS,
        ((String reason) => _finish(reason)).toJS,
      );
      if (_muted && _current) {
        _socket?.setMuted(true);
      }
    } on Object {
      _finish(_current ? 'media_unavailable' : 'account_changed');
    }
  }

  @override
  bool setMuted(bool muted) {
    if (!_current || _draining) return false;
    _muted = muted;
    final socket = _socket;
    if (socket == null) return true;
    if (!socket.setMuted(muted)) {
      _finish('transport_failed');
      return false;
    }
    return _current;
  }

  @override
  bool requestSlowPace() {
    if (!_current || _draining || _slowPaceRequested || !_active.isCompleted) {
      return false;
    }
    final socket = _socket;
    if (socket == null) return false;
    _slowPaceRequested = true;
    if (!socket.requestSlowPace()) {
      _finish('transport_failed');
      return false;
    }
    return _current;
  }

  @override
  bool interruptPlayback() {
    if (!_current ||
        _draining ||
        _muted ||
        _interruptRequested ||
        !_active.isCompleted) {
      return false;
    }
    final socket = _socket;
    if (socket == null) return false;
    _interruptRequested = true;
    if (!socket.interruptPlayback()) {
      _finish('transport_failed');
      return false;
    }
    return _current;
  }

  @override
  void holdPlayback() {
    if (!_current || _draining) throw const RealtimeFailure('cancelled');
    final socket = _socket;
    if (socket == null || !socket.holdPlayback()) {
      _finish('media_failed');
      throw const RealtimeFailure('media_failed');
    }
  }

  @override
  void beginDrain() {
    if (!_current) throw const RealtimeFailure('cancelled');
    if (_draining) return;
    final socket = _socket;
    if (socket == null || !socket.beginDrain()) {
      _finish('media_release_failed');
      throw const RealtimeFailure('media_release_failed');
    }
    _draining = true;
  }

  @override
  void stop() => _finish('local_closed');

  void _finish(String reason) {
    if (_closed) return;
    _closed = true;
    _unlisten?.call();
    _socket?.stop();
    _socket = null;
    if (_started && !_active.isCompleted) {
      _active.completeError(RealtimeFailure(reason));
    }
    onClosed(reason);
  }
}
