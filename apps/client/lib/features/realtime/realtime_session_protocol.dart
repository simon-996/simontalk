import '../practice/practice_models.dart';
import '../conversation/conversation_models.dart';
import 'realtime_transport.dart';

class RealtimeProtocolCallbacks {
  const RealtimeProtocolCallbacks({
    required this.send,
    required this.confirmConfigured,
    required this.fail,
    required this.emitConversation,
  });
  final void Function(String json, String channelId) send;
  final void Function(String channelId) confirmConfigured;
  final void Function(String code) fail;

  /// Full normalized facts on the configured channel, with stable business IDs.
  final void Function(ConversationUpdate update, String channelId)
  emitConversation;
}

/// A provider adapter validates the requested configuration before confirming it.
/// It must not treat arbitrary JSON, channel open or SDP success as readiness.
abstract interface class RealtimeSessionProtocol {
  void channelOpened(String channelId);
  void receive(RealtimeTransportEvent event);
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
