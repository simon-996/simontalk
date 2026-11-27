import '../../core/api_client.dart';
import '../practice/practice_models.dart';
import 'browser_media_session.dart';
import 'realtime_transport.dart';

RealtimeMediaSession createBrowserMediaSession({
  required ApiClient accountApi,
  required String accountId,
  required ConnectionReservation connection,
  required void Function(String kind, String payload) onEvent,
  required void Function(String reason) onClosed,
}) => _UnsupportedBrowserMediaSession();

class _UnsupportedBrowserMediaSession implements RealtimeMediaSession {
  @override
  Future<void> start() async => throw const RealtimeFailure('unsupported');

  @override
  bool setMuted(bool muted) => false;

  @override
  bool requestSlowPace() => false;

  @override
  bool interruptPlayback() => false;

  @override
  void holdPlayback() => throw const RealtimeFailure('unsupported');

  @override
  void beginDrain() => throw const RealtimeFailure('unsupported');

  @override
  void stop() {}
}
