import '../practice/practice_models.dart';
import '../conversation/conversation_models.dart';
import 'realtime_transport.dart';

enum RealtimeDrainControlKind { finishInput, cancelResponse }

/// A capability for one exact, immutable context version in the original scope.
/// A provider may acknowledge it only after verified upstream truncation.
final class RealtimeContextSnapshot {
  const RealtimeContextSnapshot({
    required this.revision,
    required this.context,
  });
  final int revision;
  final ConversationContext context;
}

class RealtimeProtocolCallbacks {
  const RealtimeProtocolCallbacks({
    required this.send,
    required this.confirmConfigured,
    required this.fail,
    required this.emitConversation,
    required this.sendDrainControl,
    required this.freezeResponse,
    required this.revokeFrozenPrefix,
    required this.prepareContext,
    required this.sendContextControl,
    required this.confirmContextTruncated,
  });
  final void Function(String json, String channelId) send;
  final void Function(String channelId) confirmConfigured;
  final void Function(String code) fail;

  /// Full normalized facts on the configured channel, with stable business IDs.
  final void Function(ConversationUpdate update, String channelId)
  emitConversation;

  /// Only input completion and cancellation of a frozen response are permitted.
  /// The adapter must validate provider semantics; this is not ordinary send.
  final void Function(
    String json,
    String channelId,
    RealtimeDrainControlKind kind,
    String? responseId,
  )
  sendDrainControl;

  /// Requires an adapter-verified device output position for this response.
  final void Function(String responseId, int stopBoundaryMs, String channelId)
  freezeResponse;

  /// An explicit, verified alignment invalidation, not a missing quality signal.
  final void Function(String responseId, String channelId) revokeFrozenPrefix;
  final RealtimeContextSnapshot? Function(String channelId) prepareContext;
  final void Function(
    String json,
    String channelId,
    RealtimeContextSnapshot snapshot,
  )
  sendContextControl;
  final void Function(RealtimeContextSnapshot snapshot, String channelId)
  confirmContextTruncated;
}

/// A provider adapter validates the requested configuration before confirming it.
/// It must not treat arbitrary JSON, channel open or SDP success as readiness.
abstract interface class RealtimeSessionProtocol {
  void channelOpened(String channelId);
  void receive(RealtimeTransportEvent event);

  /// Called once after local capture/output stop. Must never generate a reply.
  void beginDrain();
  void dispose();
}

typedef RealtimeProtocolFactory = RealtimeSessionProtocol Function(
  PracticeConfiguration configuration,
  RealtimeProtocolCallbacks callbacks,
);

RealtimeSessionProtocol unavailableRealtimeProtocol(
  PracticeConfiguration configuration,
  RealtimeProtocolCallbacks callbacks,
) => throw const RealtimeFailure('realtime_unavailable');
