import 'realtime_transport.dart';

bool get realtimeSupported => false;

void Function() observeRealtimeSupport(void Function(bool) onReady) => () {};

RealtimeTransport createRealtimeTransport() => _UnsupportedTransport();

class _UnsupportedTransport implements RealtimeTransport {
  @override
  Future<void> start({
    required RealtimeSignaller signaller,
    required void Function(RealtimeObservation) onObservation,
    required void Function(RealtimeTransportEvent) onEvent,
  }) async => throw const RealtimeFailure('unsupported');

  @override
  Future<void> activate(String channelId) async =>
      throw const RealtimeFailure('unsupported');

  @override
  void send(String json, String channelId) =>
      throw const RealtimeFailure('unsupported');

  @override
  void setMuted(bool muted) {}

  @override
  Future<void> resumePlayback() async =>
      throw const RealtimeFailure('unsupported');

  @override
  void holdPlayback() => throw const RealtimeFailure('unsupported');

  @override
  Future<void> releasePlayback() async =>
      throw const RealtimeFailure('unsupported');

  @override
  void beginDrain() => throw const RealtimeFailure('unsupported');

  @override
  void stop() {}
}
