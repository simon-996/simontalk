import '../../core/api_client.dart';
import '../practice/practice_models.dart';

/// One server-owned media session bound to an already-reserved connection.
///
/// Unlike WebRTC, the server performs provider configuration and turn control
/// before announcing readiness; this session never exchanges SDP or raw model
/// control frames from the client.
abstract interface class RealtimeMediaSession {
  /// Completes once server configuration is confirmed and local capture starts.
  Future<void> start();

  bool setMuted(bool muted);

  /// Requests session-scoped slower speech for subsequent assistant replies.
  bool requestSlowPace();

  /// Explicitly stops current assistant output and requests turn takeover.
  bool interruptPlayback();

  /// Silences current output without stopping input or claiming upstream exit.
  void holdPlayback();

  /// Synchronously stops capture and sound while keeping the event channel open
  /// for bounded tail transcripts.
  void beginDrain();

  /// Idempotent local shutdown. Never asserts upstream termination.
  void stop();
}

typedef RealtimeMediaSessionFactory = RealtimeMediaSession Function({
  required ConnectionReservation connection,
  required void Function(String kind, String payload) onEvent,
  required void Function(String reason) onClosed,
});

typedef RealtimeMediaSessionCreator = RealtimeMediaSession Function({
  required ApiClient accountApi,
  required String accountId,
  required ConnectionReservation connection,
  required void Function(String kind, String payload) onEvent,
  required void Function(String reason) onClosed,
});
