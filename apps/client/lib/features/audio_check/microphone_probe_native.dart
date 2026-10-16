import 'microphone_probe.dart';

bool get microphoneSupported => false;

void Function() observeMicrophoneSupport(void Function(bool) onReady) => () {};

MicrophoneProbe createMicrophoneProbe() => _UnsupportedProbe();

class _UnsupportedProbe implements MicrophoneProbe {
  @override
  Future<void> start({
    required void Function(double) onLevel,
    required void Function(String) onInterrupted,
  }) async => throw const MicrophoneFailure('unsupported');

  @override
  void stop() {}
}
