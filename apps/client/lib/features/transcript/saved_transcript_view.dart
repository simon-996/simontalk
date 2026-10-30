import 'package:flutter/material.dart';

import '../../design/account_components.dart';
import 'saved_transcript_controller.dart';
import 'saved_transcript_models.dart';

/// Pure bounded reading surface. Dynamic content follows the stable action bar.
class SavedTranscriptView extends StatelessWidget {
  const SavedTranscriptView({
    super.key,
    required this.state,
    this.page,
    this.busy = false,
    this.accountBusy = false,
    this.errorCode,
    this.hasFocus = false,
    this.onBack,
    this.backLabel = '返回复盘',
    this.onRefresh,
    this.onPrevious,
    this.onNext,
    this.onFocus,
    this.onConfirmAccount,
  });
  final SavedTranscriptState state;
  final SavedTranscriptPage? page;
  final bool busy, accountBusy, hasFocus;
  final String backLabel;
  final String? errorCode;
  final VoidCallback? onBack,
      onRefresh,
      onPrevious,
      onNext,
      onFocus,
      onConfirmAccount;
  @override
  Widget build(BuildContext context) {
    final blocked = busy || accountBusy;
    final identity = {'account_changed', 'unauthorized'}.contains(errorCode);
    final current = identity ? null : page;
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, c) {
            final gutter = c.maxWidth < 360
                ? 16.0
                : c.maxWidth < 840
                ? 24.0
                : 32.0;
            return SingleChildScrollView(
              key: const PageStorageKey('saved-transcript-scroll'),
              padding: EdgeInsets.all(gutter),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const PageIntro(
                        title: '已保存文字',
                        description: '按本次封存记录回看文字；识别可能有遗漏。',
                      ),
                      const SizedBox(height: 24),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          OutlinedButton(
                            onPressed: accountBusy ? null : onBack,
                            child: Text(backLabel),
                          ),
                          if (identity)
                            OutlinedButton(
                              onPressed: blocked ? null : onConfirmAccount,
                              child: const Text('重新确认账号'),
                            )
                          else
                            OutlinedButton(
                              onPressed: blocked ? null : onRefresh,
                              child: const Text('刷新已保存文字'),
                            ),
                          OutlinedButton(
                            onPressed:
                                blocked || current?.previousOffset == null
                                ? null
                                : onPrevious,
                            child: const Text('上一页'),
                          ),
                          OutlinedButton(
                            onPressed: blocked || current?.nextOffset == null
                                ? null
                                : onNext,
                            child: const Text('下一页'),
                          ),
                          if (hasFocus)
                            OutlinedButton(
                              onPressed: blocked ? null : onFocus,
                              child: const Text('回到原话'),
                            ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      if (accountBusy) ...[
                        const StatusMessage('账号操作进行中，请稍候…', error: false),
                        const SizedBox(height: 12),
                      ],
                      Semantics(
                        liveRegion: true,
                        header: true,
                        child: Text(
                          _status(current),
                          style: theme.textTheme.titleLarge,
                        ),
                      ),
                      if (errorCode != null) ...[
                        const SizedBox(height: 12),
                        StatusMessage(
                          _error(errorCode!, retained: current != null),
                        ),
                      ],
                      if (current != null) ...[
                        const SizedBox(height: 16),
                        if (current.coverage == 'incomplete') ...[
                          const Text('本次保存仍有缺口，以下只展示已经保存的部分。'),
                          const SizedBox(height: 12),
                        ],
                        const Text('AI 的播放片段来自客户端报告，不能证明设备确实播放或远端连接已结束。'),
                        if (current.focus != null &&
                            !current.items.any(current.focus!.matches)) ...[
                          const SizedBox(height: 12),
                          const Text('建议对应原话在其他页，可选择“回到原话”重新读取。'),
                        ],
                        const SizedBox(height: 24),
                        SelectionArea(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (
                                var i = 0;
                                i < current.items.length;
                                i++
                              ) ...[
                                if (i == 0 ||
                                    current.items[i].connectionId !=
                                        current.items[i - 1].connectionId) ...[
                                  Semantics(
                                    header: true,
                                    child: Text(
                                      '连接段 ${current.items[i].epoch}',
                                      style: theme.textTheme.titleMedium,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                ],
                                _TurnCard(
                                  key: ValueKey(
                                    '${current.items[i].connectionId}/${current.items[i].turnId}',
                                  ),
                                  turn: current.items[i],
                                  focus: current.focus,
                                ),
                                const SizedBox(height: 16),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  String _status(SavedTranscriptPage? p) {
    if (busy ||
        state == SavedTranscriptState.reading ||
        state == SavedTranscriptState.idle) {
      return '正在读取已保存文字…';
    }
    if (p != null) {
      return p.totalTurns == 0
          ? '本次没有已保存文字'
          : p.items.isEmpty
          ? '已到记录末尾（共 ${p.totalTurns} 段）'
          : '第 ${p.offset + 1}–${p.offset + p.items.length} 段，共 ${p.totalTurns} 段';
    }
    return '暂时无法读取已保存文字';
  }
}

class _TurnCard extends StatelessWidget {
  const _TurnCard({super.key, required this.turn, required this.focus});
  final SavedTranscriptTurn turn;
  final SavedTranscriptFocus? focus;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final target = focus?.matches(turn) ?? false;
    final user = turn.role == 'user';
    return Material(
      color: t.colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: target ? t.colorScheme.primary : t.colorScheme.outlineVariant,
          width: target ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                '${turn.ordinal} · ${user ? '你' : 'AI'}',
                style: t.textTheme.titleMedium,
              ),
            ),
            if (target) ...[
              const SizedBox(height: 12),
              Text('建议对应原话', style: t.textTheme.labelLarge),
              const SizedBox(height: 8),
              Text('精确引用：${focus!.exactQuote}'),
            ],
            const SizedBox(height: 16),
            if (user)
              Text(turn.finalText!.isEmpty ? '这段没有可用文字' : turn.finalText!)
            else ...[
              if (turn.playedText != null) ...[
                Text('客户端报告的播放片段', style: t.textTheme.labelLarge),
                if (turn.playedRevision != turn.revision) ...[
                  const SizedBox(height: 8),
                  Text(
                    '此前版本（修订 ${turn.playedRevision}；当前保存修订 ${turn.revision}）',
                  ),
                ],
                const SizedBox(height: 8),
                Text(turn.playedText!),
              ] else
                Text(switch (turn.playbackStatus) {
                  'revoked' => '这段播放证据已撤销，不能作为已播放内容展示。',
                  'not_played' => '客户端报告这段没有播放。',
                  _ => '这段没有有效播放证据，无法确认播放内容。',
                }),
              if (turn.finalText != null) ...[
                const SizedBox(height: 12),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 12),
                  title: const Text('查看已保存生成文字（不代表已播放）'),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        turn.finalText!.isEmpty
                            ? '这段没有可用生成文字'
                            : turn.finalText!,
                      ),
                    ),
                  ],
                ),
              ] else ...[
                const SizedBox(height: 12),
                const Text('没有已保存的最终生成文字。'),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

String _error(String code, {required bool retained}) => switch (code) {
  'account_changed' => '当前账号已变化，请重新确认账号后查看。',
  'unauthorized' => '登录已失效，请重新确认账号。',
  'invalid_source' => '练习地址无效，请返回复盘。',
  'completion_not_sealed' => '本次文字尚未完成封存，可以稍后刷新。',
  'saved_transcript_limit_exceeded' => '这次练习超出当前文字读取范围，请联系维护者。',
  'saved_transcript_changed' ||
  'invalid_response' => '保存来源或响应校验未通过，旧文字已撤下，请刷新重试。',
  'review_item_not_found' ||
  'practice_not_found' ||
  'completion_not_found' => '这份记录或建议已不可用，请返回复盘。',
  _ => retained ? '翻页未成功，仍显示上一已读取页。请检查网络后重试原操作。' : '暂时无法读取，请检查网络后刷新重试。',
};
