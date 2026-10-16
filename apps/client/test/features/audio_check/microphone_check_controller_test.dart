import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/audio_check/microphone_probe.dart';
import 'package:simontalk_client/features/audio_check/microphone_check_controller.dart';

class TestProbe implements MicrophoneProbe {
  final permission = Completer<void>();
  int stops = 0;
  void Function(double)? level;
  void Function(String)? interrupted;

  @override
  Future<void> start({
    required void Function(double) onLevel,
    required void Function(String) onInterrupted,
  }) {
    level = onLevel;
    interrupted = onInterrupted;
    return permission.future;
  }

  @override
  void stop() => stops++;
}

void main() {
  late List<TestProbe> probes;
  late MicrophoneCheckController controller;

  setUp(() {
    probes = [];
    controller = MicrophoneCheckController(
      supported: true,
      createProbe: () {
        final probe = TestProbe();
        probes.add(probe);
        return probe;
      },
    );
  });
  tearDown(() => controller.dispose());

  testWidgets('does not request until start and rejects duplicate starts', (
    tester,
  ) async {
    expect(probes, isEmpty);
    final pending = controller.start();
    unawaited(controller.start());
    expect(probes, hasLength(1));
    expect(controller.status, MicrophoneCheckStatus.requesting);
    controller.stop();
    expect(probes.single.stops, 1);
    probes.single.permission.complete();
    await pending;
    expect(controller.status, MicrophoneCheckStatus.stopped);
  });

  testWidgets('permission wait times out without adopting a late result', (
    tester,
  ) async {
    final pending = controller.start();
    await tester.pump(const Duration(seconds: 20));
    expect(controller.status, MicrophoneCheckStatus.failed);
    expect(controller.errorCode, 'permission_timeout');
    expect(probes.single.stops, 1);
    probes.single.permission.complete();
    await pending;
    expect(controller.status, MicrophoneCheckStatus.failed);
  });

  testWidgets('capture ends after thirty seconds and releases immediately', (
    tester,
  ) async {
    final pending = controller.start();
    probes.single.permission.complete();
    await pending;
    expect(controller.status, MicrophoneCheckStatus.checking);
    await tester.pump(const Duration(seconds: 30));
    expect(controller.status, MicrophoneCheckStatus.stopped);
    expect(controller.remainingSeconds, 0);
    expect(probes.single.stops, 1);
  });

  testWidgets('old results and callbacks cannot alter a new attempt', (
    tester,
  ) async {
    final first = controller.start();
    final old = probes.single;
    controller.stop();
    final second = controller.start();
    final current = probes.last;
    old.level!(1);
    old.interrupted!('background');
    old.permission.completeError(const MicrophoneFailure('permission_denied'));
    await first;
    expect(controller.status, MicrophoneCheckStatus.requesting);
    expect(controller.level, 0);
    expect(current.stops, 0);
    current.permission.complete();
    await second;
    expect(controller.status, MicrophoneCheckStatus.checking);
    controller.stop();
  });

  testWidgets('denial has actionable feedback and no active resources', (
    tester,
  ) async {
    final pending = controller.start();
    probes.single.permission.completeError(
      const MicrophoneFailure('permission_denied'),
    );
    await pending;
    expect(controller.status, MicrophoneCheckStatus.failed);
    expect(controller.message, contains('允许'));
    expect(probes.single.stops, 1);
  });

  testWidgets('background and track endings stop the current check', (
    tester,
  ) async {
    final pending = controller.start();
    probes.single.permission.complete();
    await pending;
    probes.single.interrupted!('background');
    expect(controller.status, MicrophoneCheckStatus.stopped);
    expect(controller.message, contains('返回后'));
    expect(probes.single.stops, 1);
  });

  testWidgets(
    'levels are finite and bounded without implying speech recognition',
    (tester) async {
      final pending = controller.start();
      probes.single.permission.complete();
      await pending;
      probes.single.level!(2);
      expect(controller.level, 1);
      probes.single.level!(double.nan);
      expect(controller.level, 0);
      expect(controller.hasInputLevel, isTrue);
      controller.stop();
      expect(controller.level, 0);
    },
  );

  testWidgets(
    'dispose ignores late media and does not notify disposed listeners',
    (tester) async {
      final pending = controller.start();
      var changes = 0;
      controller.addListener(() => changes++);
      controller.dispose();
      probes.single.level!(1);
      probes.single.interrupted!('device_lost');
      probes.single.permission.complete();
      await pending;
      expect(changes, 0);
      expect(probes.single.stops, 1);
    },
  );

  testWidgets('unsupported platforms never create a capture', (tester) async {
    controller.dispose();
    controller = MicrophoneCheckController(
      supported: false,
      createProbe: () => throw StateError('capture'),
    );
    await controller.start();
    expect(controller.status, MicrophoneCheckStatus.unsupported);
    expect(probes, isEmpty);
  });

  testWidgets(
    'late capability readiness enables checking after preparation timeout',
    (tester) async {
      controller.dispose();
      controller = MicrophoneCheckController(
        supported: null,
        createProbe: () {
          final p = TestProbe();
          probes.add(p);
          return p;
        },
      );
      expect(controller.status, MicrophoneCheckStatus.preparing);
      await controller.start();
      expect(probes, isEmpty);
      await tester.pump(const Duration(seconds: 20));
      expect(controller.status, MicrophoneCheckStatus.unsupported);
      controller.updateSupport(true);
      expect(controller.status, MicrophoneCheckStatus.idle);
      expect(probes, isEmpty);
      controller.dispose();
      controller.updateSupport(true);
    },
  );
}
