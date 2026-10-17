import 'package:simontalk_client/features/realtime/realtime_transport.dart';
import 'package:simontalk_client/features/realtime/realtime_transport_factory.dart';

class _Signaller implements RealtimeSignaller {
  _Signaller({this.fail = false});
  final bool fail;
  int exchanges = 0;
  int cancellations = 0;

  @override
  Future<String> exchangeOffer(String offer) async {
    if (offer != 'v=0\r\no=offer\r\n') throw StateError('wrong offer');
    exchanges++;
    await Future<void>.delayed(Duration.zero);
    if (fail) throw StateError('private upstream details');
    return 'v=0\r\no=answer\r\n';
  }

  @override
  void cancel() => cancellations++;
}

void check(bool condition) {
  if (!condition) throw StateError('bridge assertion failed');
}

Future<void> main() async {
  check(realtimeSupported == true);
  final signaller = _Signaller();
  final transport = createRealtimeTransport();
  final events = <RealtimeTransportEvent>[];
  final observations = <RealtimeObservation>[];
  await transport.start(
    signaller: signaller,
    onObservation: observations.add,
    onEvent: events.add,
  );
  check(signaller.exchanges == 1);
  check(events.single.channelId == 'server-channel');
  check(events.single.json == '{"type":"session.created"}');
  check(observations.single.code == 'transport_connected');
  transport.send('{"type":"session.update"}', events.single.channelId);
  await transport.activate(events.single.channelId);
  transport.setMuted(true);
  try {
    await transport.resumePlayback();
    throw StateError('missing playback failure');
  } on RealtimeFailure catch (error) {
    check(error.code == 'playback_blocked');
  }
  transport.stop();
  transport.stop();
  check(signaller.cancellations == 1);
  check(observations.last.code == 'local_closed');
  final failingSignaller = _Signaller(fail: true);
  final failing = createRealtimeTransport();
  try {
    await failing.start(
      signaller: failingSignaller,
      onObservation: (_) {},
      onEvent: (_) {},
    );
    throw StateError('missing signalling failure');
  } on RealtimeFailure catch (error) {
    check(error.code == 'connection_failed');
  }
  check(failingSignaller.cancellations == 1);
  // Test harness completion marker consumed by the Node runner.
  // ignore: avoid_print
  print('realtime-bridge-passed');
}
