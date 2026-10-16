import 'dart:async';

import 'package:flutter/foundation.dart';

import 'microphone_probe.dart';

enum MicrophoneCheckStatus {
  preparing,
  idle,
  requesting,
  checking,
  stopped,
  failed,
  unsupported,
}

class MicrophoneCheckController extends ChangeNotifier {
  MicrophoneCheckController({
    required bool? supported,
    required this.createProbe,
  }) : status = supported == null
           ? MicrophoneCheckStatus.preparing
           : supported
           ? MicrophoneCheckStatus.idle
           : MicrophoneCheckStatus.unsupported {
    if (supported == null) {
      _availabilityTimer = Timer(
        const Duration(seconds: 20),
        () => updateSupport(false),
      );
    }
  }

  final MicrophoneProbeFactory createProbe;
  MicrophoneCheckStatus status;
  double level = 0;
  bool hasInputLevel = false;
  int remainingSeconds = 30;
  String? errorCode;
  String? _stopMessage;
  int _generation = 0;
  bool _disposed = false;
  MicrophoneProbe? _probe;
  Timer? _permissionTimer;
  Timer? _captureTimer;
  Timer? _availabilityTimer;

  String get message => switch (status) {
    MicrophoneCheckStatus.preparing => '正在准备麦克风检查，账号设置仍可使用。',
    MicrophoneCheckStatus.idle => '准备好后，允许浏览器使用麦克风。',
    MicrophoneCheckStatus.requesting => '请在浏览器中选择允许，也可以随时取消等待。',
    MicrophoneCheckStatus.checking => '请说一句英语，观察输入音量是否变化。',
    MicrophoneCheckStatus.stopped => _stopMessage ?? '检查已结束，麦克风已关闭。',
    MicrophoneCheckStatus.unsupported =>
      '当前入口未能准备好麦克风检查。可重新加载页面，或使用 HTTPS 或本机地址在支持音频的浏览器中打开。',
    MicrophoneCheckStatus.failed => switch (errorCode) {
      'permission_denied' => '尚未获得麦克风权限。请在浏览器的网站设置中允许麦克风后重试。',
      'permission_timeout' => '等待授权已结束。如浏览器仍显示许可提示，可关闭提示或处理后重新检查。',
      'no_device' => '没有找到麦克风。请连接设备，再重新检查。',
      'device_busy' => '暂时无法使用麦克风。请检查系统权限，或关闭可能占用麦克风的应用后重试。',
      'device_lost' => '音频设备已断开或停止，麦克风检查已结束。请检查连接后重试。',
      _ => '暂时无法检查麦克风。请确认设备和浏览器支持音频后重试。',
    },
  };

  bool _current(int generation) => !_disposed && generation == _generation;

  void updateSupport(bool supported) {
    if (_disposed ||
        (status != MicrophoneCheckStatus.preparing &&
            status != MicrophoneCheckStatus.unsupported)) {
      return;
    }
    _availabilityTimer?.cancel();
    status = supported
        ? MicrophoneCheckStatus.idle
        : MicrophoneCheckStatus.unsupported;
    notifyListeners();
  }

  Future<void> start() async {
    if (_disposed ||
        status == MicrophoneCheckStatus.preparing ||
        status == MicrophoneCheckStatus.requesting ||
        status == MicrophoneCheckStatus.checking ||
        status == MicrophoneCheckStatus.unsupported) {
      return;
    }
    final generation = ++_generation;
    status = MicrophoneCheckStatus.requesting;
    level = 0;
    hasInputLevel = false;
    remainingSeconds = 30;
    errorCode = null;
    _stopMessage = null;
    notifyListeners();
    if (!_current(generation)) return;
    _permissionTimer = Timer(const Duration(seconds: 20), () {
      if (_current(generation)) _fail('permission_timeout');
    });
    try {
      final probe = createProbe();
      _probe = probe;
      await probe.start(
        onLevel: (value) {
          if (!_current(generation) ||
              status != MicrophoneCheckStatus.checking) {
            return;
          }
          level = value.isFinite ? value.clamp(0, 1).toDouble() : 0;
          hasInputLevel = hasInputLevel || level > 0.02;
          notifyListeners();
        },
        onInterrupted: (reason) {
          if (!_current(generation)) return;
          if (reason == 'background') {
            stop(message: '页面已离开前台，麦克风已关闭。返回后可重新检查。');
          } else {
            _fail('device_lost');
          }
        },
      );
      if (!_current(generation)) return;
      _permissionTimer?.cancel();
      status = MicrophoneCheckStatus.checking;
      _captureTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!_current(generation)) return;
        remainingSeconds = (30 - timer.tick).clamp(0, 30);
        if (remainingSeconds == 0) {
          stop();
        } else {
          notifyListeners();
        }
      });
      notifyListeners();
    } on MicrophoneFailure catch (error) {
      if (_current(generation)) _fail(error.code);
    } catch (_) {
      if (_current(generation)) _fail('unavailable');
    }
  }

  void _release() {
    _generation++;
    _permissionTimer?.cancel();
    _captureTimer?.cancel();
    _availabilityTimer?.cancel();
    final probe = _probe;
    _probe = null;
    probe?.stop();
    level = 0;
  }

  void _fail(String code) {
    _release();
    errorCode = code;
    status = MicrophoneCheckStatus.failed;
    notifyListeners();
  }

  void stop({String? message}) {
    if (_disposed ||
        (status != MicrophoneCheckStatus.requesting &&
            status != MicrophoneCheckStatus.checking)) {
      return;
    }
    final waiting = status == MicrophoneCheckStatus.requesting;
    _release();
    status = MicrophoneCheckStatus.stopped;
    _stopMessage =
        message ??
        (waiting ? '已取消等待。如浏览器仍显示许可提示，可关闭它；晚到授权不会继续采集。' : '检查已结束，麦克风已关闭。');
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _release();
    super.dispose();
  }
}
