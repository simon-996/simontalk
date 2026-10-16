abstract interface class MicrophoneProbe {
  Future<void> start({
    required void Function(double) onLevel,
    required void Function(String) onInterrupted,
  });

  void stop();
}

typedef MicrophoneProbeFactory = MicrophoneProbe Function();

class MicrophoneFailure implements Exception {
  const MicrophoneFailure(this.code);
  final String code;
}
