import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../design/account_components.dart';
import '../../design/app_theme.dart';
import 'microphone_check_controller.dart';
import 'microphone_probe.dart';
import 'microphone_probe_factory.dart';

class MicrophoneCheckPanel extends StatefulWidget {
  const MicrophoneCheckPanel({super.key, this.createProbe, this.supported});
  final MicrophoneProbeFactory? createProbe;
  final bool? supported;

  @override
  State<MicrophoneCheckPanel> createState() => _MicrophoneCheckPanelState();
}

class _MicrophoneCheckPanelState extends State<MicrophoneCheckPanel>
    with WidgetsBindingObserver {
  late final MicrophoneCheckController _controller;
  void Function()? _stopObservingSupport;

  @override
  void initState() {
    super.initState();
    _controller = MicrophoneCheckController(
      supported: widget.supported ?? microphoneSupported,
      createProbe: widget.createProbe ?? createMicrophoneProbe,
    );
    if (widget.supported == null) {
      _stopObservingSupport = observeMicrophoneSupport(
        _controller.updateSupport,
      );
    }
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _controller.stop(message: '页面已离开前台，麦克风已关闭。返回后可重新检查。');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopObservingSupport?.call();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) => MicrophoneCheckView(
      status: _controller.status,
      message: _controller.message,
      level: _controller.level,
      hasInputLevel: _controller.hasInputLevel,
      remainingSeconds: _controller.remainingSeconds,
      onStart: _controller.start,
      onStop: _controller.stop,
    ),
  );
}

class MicrophoneCheckView extends StatelessWidget {
  const MicrophoneCheckView({
    super.key,
    required this.status,
    required this.message,
    this.level = 0,
    this.hasInputLevel = false,
    this.remainingSeconds = 30,
    this.onStart,
    this.onStop,
  });

  final MicrophoneCheckStatus status;
  final String message;
  final double level;
  final bool hasInputLevel;
  final int remainingSeconds;
  final VoidCallback? onStart;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final checking = status == MicrophoneCheckStatus.checking;
    final requesting = status == MicrophoneCheckStatus.requesting;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SectionHeading('麦克风检查'),
            const SizedBox(height: 12),
            Text(
              '只在本机观察输入音量，不录音、不上传。每次最多30秒。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            Semantics(liveRegion: true, child: Text(message)),
            if (checking) ...[
              const SizedBox(height: 20),
              Semantics(
                label: '麦克风输入音量',
                value: hasInputLevel ? '检测到输入音量' : '暂未检测到明显音量',
                child: ExcludeSemantics(
                  child: LinearProgressIndicator(
                    value: level,
                    minHeight: 10,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '剩余 $remainingSeconds 秒 · 输入音量不代表语音识别或发音评分',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 20),
            if (checking || requesting)
              OutlinedButton.icon(
                onPressed: onStop,
                icon: Icon(checking ? Icons.stop_rounded : Icons.close_rounded),
                label: Text(checking ? '停止检查' : '取消等待'),
              )
            else if (status == MicrophoneCheckStatus.preparing)
              const OutlinedButton(onPressed: null, child: Text('正在准备检查'))
            else if (status != MicrophoneCheckStatus.unsupported)
              OutlinedButton.icon(
                onPressed: onStart,
                icon: const Icon(Icons.mic_none_rounded),
                label: Text(
                  status == MicrophoneCheckStatus.idle ? '开始检查' : '重新检查',
                ),
              ),
          ],
        ),
      ),
    );
  }
}

@Preview(name: '麦克风 · 许可失败 · 浅色', size: Size(320, 760))
Widget microphoneFailurePreview() => MaterialApp(
  theme: buildAppTheme(Brightness.light),
  home: const Scaffold(
    body: SingleChildScrollView(
      child: MicrophoneCheckView(
        status: MicrophoneCheckStatus.failed,
        message: '组件预览：尚未获得麦克风权限，请在网站设置中允许后重试。',
      ),
    ),
  ),
);

@Preview(name: '麦克风 · 等待 · 深色大字号', size: Size(320, 880))
Widget microphoneWaitingPreview() => MaterialApp(
  theme: buildAppTheme(Brightness.dark),
  home: const MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(2)),
    child: Scaffold(
      body: SingleChildScrollView(
        child: MicrophoneCheckView(
          status: MicrophoneCheckStatus.requesting,
          message: '组件预览：等待浏览器授权，可以取消。',
        ),
      ),
    ),
  ),
);
