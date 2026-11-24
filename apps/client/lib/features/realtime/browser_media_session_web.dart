import 'dart:async';
import 'dart:js_interop';

import '../../core/api_client.dart';
import '../practice/practice_models.dart';
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
}

/// One explicitly started browser connection to a same-origin media gateway.
class BrowserMediaSession {
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
  bool _started = false;
  bool _closed = false;

  bool get _current => !_closed && api.hasCurrentAccount(accountId);

  /// Completes once capture is running and the initial mode has been sent.
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
      _socket = _open(
        path,
        (() => proof.consume()).toJS,
        (() => _current).toJS,
        ((String kind, String payload) {
          if (!_current) return;
          if (kind == 'active') _active.complete();
          onEvent(kind, payload);
        }).toJS,
        ((String reason) => _finish(reason)).toJS,
      );
    } on Object {
      _finish(_current ? 'media_unavailable' : 'account_changed');
    }
  }

  bool setMuted(bool muted) => _current && (_socket?.setMuted(muted) ?? false);

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
