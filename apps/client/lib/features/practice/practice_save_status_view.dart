import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../design/app_theme.dart';
import '../../design/preview_surface.dart';
import '../conversation/conversation_models.dart';
import 'practice_completion_models.dart';
import 'practice_models.dart';
import 'termination_check_models.dart';

/// An explicit, read-only snapshot; viewing never submits or ends a practice.
class PracticeSaveStatusView extends StatelessWidget {
  const PracticeSaveStatusView({
    super.key,
    this.loaded = false,
    this.busy = false,
    this.completion,
    this.terminationCheck,
    this.terminationStatus = TerminationStatus.unknown,
    this.errorCode,
    this.onLoad,
    this.onRefresh,
  });

  final bool loaded;
  final bool busy;
  final PracticeCompletionSummary? completion;
  final TerminationCheckSnapshot? terminationCheck;
  final TerminationStatus terminationStatus;
  final String? errorCode;
  final VoidCallback? onLoad;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sealed = completion?.status == PracticeCompletionStatus.sealed;
    final complete =
        completion?.coverage == PracticeCompletionCoverage.complete;
    final headline = errorCode != null
        ? '暂时无法读取保存状态'
        : busy
        ? '正在核对保存状态…'
        : !loaded
        ? '查看服务器已收到的记录和保存缺口。'
        : completion == null
        ? '尚未登记结束保存'
        : !sealed
        ? '正在保存本次记录'
        : complete
        ? '记录已保存'
        : '已有内容已保存，仍有缺口';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('保存状态', style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),
        Semantics(
          liveRegion: true,
          child: Text(
            headline,
            style: errorCode == null
                ? theme.textTheme.bodyLarge
                : theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.error,
                  ),
          ),
        ),
        if (errorCode != null) ...[
          const SizedBox(height: 8),
          const Text('请检查网络后重试。这次读取未能确认最新状态。'),
        ] else if (!busy && loaded) ...[
          const SizedBox(height: 8),
          if (completion == null)
            const Text('服务器尚无这次练习的结束保存记录。查看不会替你结束练习或提交内容。')
          else if (!sealed)
            Text(
              '已登记结束保存，正在等待封存结果。收尾内容接收截止为 ${_date(completion!.finalUploadDeadline)}；刷新不会延长接收时间。',
            )
          else ...[
            if (complete)
              const Text('本次登记范围内的内容已保存。文字仅包含已经完成识别的部分。')
            else
              for (final reason in _gapReasons(completion!.gapCodes))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(reason),
                ),
            const SizedBox(height: 4),
            const Text('这份记录已结束接收新内容。刷新不能补回未收到的片段。'),
          ],
          if (terminationCheck != null) ...[
            const SizedBox(height: 24),
            Text('连接与用量', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(_terminationMessage(terminationStatus, terminationCheck!)),
          ],
        ],
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: busy
              ? null
              : loaded || errorCode != null
              ? onRefresh
              : onLoad,
          child: Text(
            errorCode != null
                ? '重试读取保存状态'
                : loaded
                ? '刷新保存状态'
                : '查看保存状态',
          ),
        ),
      ],
    );
  }
}

List<String> _gapReasons(List<String> codes) {
  final gaps = codes.toSet();
  bool has(Set<String> group) => gaps.any(group.contains);
  return [
    if (has({'transcript_missing', 'transcript_rejected'})) '部分文字未保存。',
    if (has({'playback_missing', 'playback_rejected'})) '部分 AI 输出记录未保存。',
    if (has({'unfinalized_turn', 'tail_unconfirmed'})) '部分话语可能未完成识别。',
    if (has({
      'unconfirmed_response',
      'playback_unconfirmed',
      'playback_revoked',
    }))
      '部分 AI 回复的实际播放情况无法确认。',
    if (gaps.contains('tail_aborted')) '收尾提前中断，最后一段可能不完整。',
    if (has({
      'manifest_missing',
      'manifest_totals_mismatch',
      'transcript_unexpected',
      'playback_unexpected',
      'journal_unavailable',
    }))
      '部分内容的保存范围未能完整核对。',
  ];
}

String _terminationMessage(
  TerminationStatus status,
  TerminationCheckSnapshot check,
) => switch (status) {
  TerminationStatus.notStarted => '服务端记录：尚未开始远端媒体。',
  TerminationStatus.confirmed => '服务端已记录远端结束确认。实际用量仍需另行核对。',
  TerminationStatus.unknown
      when check.status == TerminationCheckStatus.blocked =>
    '自动核验暂不可用，需要维护者协助确认。确认前暂不能开始新的练习。',
  TerminationStatus.unknown => '远端是否结束尚未确认，服务端尚无自动核验记录。实际用量仍待核对。',
};

String _date(DateTime time) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

final _previewScope = ConversationScope(
  accountId: '11111111-1111-4111-8111-111111111111',
  sessionId: '22222222-2222-4222-8222-222222222222',
  connectionId: '33333333-3333-4333-8333-333333333333',
  clientInstanceId: '44444444-4444-4444-8444-444444444444',
  epoch: 1,
);

// Preview-only fixture; no account, repository, or media is created.
Widget _savedPreview(
  Brightness brightness, {
  bool large = false,
  bool complete = false,
}) => MaterialApp(
  theme: buildAppTheme(brightness),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(large ? 2 : 1)),
    child: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: PracticeSaveStatusView(
          loaded: true,
          completion: PracticeCompletionSummary.fromJson({
            'source': 'server_recorded',
            'account_id': _previewScope.accountId,
            'session_id': _previewScope.sessionId,
            'origin_connection_id': _previewScope.connectionId,
            'client_instance_id': _previewScope.clientInstanceId,
            'epoch': 1,
            'end_key': '55555555-5555-4555-8555-555555555555',
            'status': 'sealed',
            'accepted_at': '2026-10-21T08:00:00Z',
            'final_upload_deadline': '2026-10-21T08:00:30Z',
            'sealed_at': '2026-10-21T08:00:01Z',
            'input_revision': 1,
            'input_hash': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            'coverage': complete ? 'complete' : 'incomplete',
            'connection_count': 1,
            'gap_codes': complete
                ? <String>[]
                : ['tail_unconfirmed', 'transcript_missing'],
          }, scope: _previewScope),
          terminationCheck: TerminationCheckSnapshot(
            scope: _previewScope,
            status: TerminationCheckStatus.blocked,
            reason: 'capability_unavailable',
            attempts: 0,
            createdAt: DateTime.utc(2026, 10, 21, 8),
          ),
          onRefresh: () {},
        ),
      ),
    ),
  ),
);

@Preview(
  name: '保存状态 · 缺口 · 浅色',
  size: Size(375, 880),
  wrapper: previewWithFonts,
)
Widget savedStatusLightPreview() => _savedPreview(Brightness.light);

@Preview(
  name: '保存状态 · 缺口 · 深色大字号',
  size: Size(320, 1280),
  brightness: Brightness.dark,
  wrapper: previewWithFonts,
)
Widget savedStatusDarkLargePreview() =>
    _savedPreview(Brightness.dark, large: true);

@Preview(
  name: '保存状态 · 完整 · 深色',
  size: Size(375, 880),
  brightness: Brightness.dark,
  wrapper: previewWithFonts,
)
Widget savedStatusCompletePreview() =>
    _savedPreview(Brightness.dark, complete: true);
