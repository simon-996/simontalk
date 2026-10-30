/// One signaller per connection attempt. Never automatically replay an SDP exchange.
/// Implementations own their request cancellation; they do not share account clients.
abstract interface class RealtimeSignaller {
  Future<String> exchangeOffer(String offer);
  void cancel();
}

/// Transport observations are local evidence, not upstream billing confirmation.
class RealtimeObservation {
  const RealtimeObservation(this.code, this.detail);
  final String code;
  final String detail;
}

/// Only a provider adapter interprets this JSON. It is not a final business turn.
class RealtimeTransportEvent {
  const RealtimeTransportEvent(this.json, this.channelId);
  final String json;
  final String channelId;
}

abstract interface class RealtimeTransport {
  /// Completes when transport and an event channel are connected, before model readiness.
  Future<void> start({
    required RealtimeSignaller signaller,
    required void Function(RealtimeObservation) onObservation,
    required void Function(RealtimeTransportEvent) onEvent,
  });

  /// Provider adapter calls this only after confirming the requested model configuration.
  /// Use the channel ID that delivered the corresponding model session events.
  /// Completes after microphone attachment; playback is observed independently.
  Future<void> activate(String channelId);
  void send(String json, String channelId);
  void setMuted(bool muted);
  Future<void> resumePlayback();

  /// Synchronously stops capture and sound, keeping the configured event channel
  /// for bounded tail evidence and provider completion/cancel controls only.
  /// Requires an active transport; cannot activate media again. The owner bounds
  /// the wait and validates tail events and controls, then calls [stop].
  void beginDrain();

  /// Idempotent local shutdown. Does not assert that upstream charges have stopped.
  void stop();
}

class RealtimeFailure implements Exception {
  const RealtimeFailure(this.code);
  final String code;

  @override
  String toString() => 'RealtimeFailure($code)';
}
