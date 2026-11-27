import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/account_components.dart';
import '../../design/app_theme.dart';
import '../../design/preview_surface.dart';
import '../account/account_controller.dart';
import '../conversation/final_transcript_read_models.dart';
import '../conversation/final_transcript_read_view.dart';
import 'connection_observation_models.dart';
import 'practice_models.dart';
import 'practice_completion_models.dart';
import 'practice_save_status_view.dart';
import 'termination_check_models.dart';
import 'practice_providers.dart';
import 'practice_recovery_controller.dart';
import 'preparation_discard_dialog.dart';

class PracticeRecoveryPanel extends ConsumerWidget {
  const PracticeRecoveryPanel({
    super.key,
    this.recoveryController,
    this.showAccountStatus = true,
  });
  final bool showAccountStatus;
  final PracticeRecoveryController? recoveryController;

  Future<void> _confirmDiscard(
    BuildContext context,
    PracticeRecoveryController controller,
    PracticePreparation original,
    bool Function() canAct,
  ) async {
    if (!canAct() ||
        !identical(original, controller.recovery?.practice) ||
        controller.endRegistered ||
        !(controller.recovery?.canDiscardPreparation ?? false)) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => const PreparationDiscardDialog(),
    );
    if (confirmed == true &&
        canAct() &&
        identical(original, controller.recovery?.practice)) {
      await controller.discardPreparation(original);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller =
        recoveryController ?? ref.watch(practiceRecoveryProvider);
    final account = ref.watch(accountControllerProvider);
    if (controller == null) return const SizedBox.shrink();
    final displayedUri = GoRouter.maybeOf(context)
        ?.routeInformationProvider
        .value
        .uri;
    bool canAct({bool requireApiOwner = true}) {
      if (!context.mounted ||
          ModalRoute.of(context)?.isCurrent != true ||
          GoRouter.maybeOf(context)?.routeInformationProvider.value.uri !=
              displayedUri) {
        return false;
      }
      final current = ref.read(accountControllerProvider);
      final activePanel = context.widget;
      if (activePanel is! PracticeRecoveryPanel) return false;
      final active =
          activePanel.recoveryController ?? ref.read(practiceRecoveryProvider);
      return current.phase == SessionPhase.signedIn &&
          !current.busy &&
          current.session?.user.id == controller.accountId &&
          identical(controller, active) &&
          !controller.busy &&
          (!requireApiOwner ||
              ref
                  .read(accountRepositoryProvider)
                  .api
                  .hasCurrentAccount(controller.accountId));
    }

    return ListenableBuilder(
      listenable: controller,
      builder: (viewContext, _) {
        final displayedRecovery = controller.recovery;
        final displayedCompletion = controller.savedCompletion;
        bool hasRecovery() =>
            canAct() &&
            displayedRecovery != null &&
            identical(controller.recovery, displayedRecovery);
        return PracticeRecoveryView(
          busy: controller.busy,
          accountBusy: account.busy,
          showAccountStatus: showAccountStatus,
          recovery: displayedRecovery,
          page: controller.page,
          events: controller.events,
          errorCode: controller.errorCode,
          observationErrorCode: controller.observationErrorCode,
          transcripts: controller.transcripts,
          transcriptErrorCode: controller.transcriptErrorCode,
          loadingTranscripts: controller.loadingTranscripts,
          savedCompletion: displayedCompletion,
          endRegistered: controller.endRegistered,
          terminationCheck: controller.terminationCheck,
          saveStatusLoaded: controller.saveStatusLoaded,
          loadingSaveStatus: controller.loadingSaveStatus,
          saveStatusErrorCode: controller.saveStatusErrorCode,
          onOpenReview: () {
            if (!hasRecovery() ||
                displayedCompletion == null ||
                !identical(controller.savedCompletion, displayedCompletion) ||
                !controller.saveStatusLoaded ||
                controller.errorCode != null ||
                controller.saveStatusErrorCode != null ||
                displayedCompletion.status != PracticeCompletionStatus.sealed ||
                displayedCompletion.scope.accountId != controller.accountId ||
                displayedCompletion.scope.sessionId !=
                    displayedRecovery?.practice?.id) {
              return;
            }
            context.push(
              '/practice/${displayedCompletion.scope.sessionId}/review',
            );
          },
          onLoadSaveStatus: () {
            if (hasRecovery()) unawaited(controller.loadSaveStatus());
          },
          onRefreshSaveStatus: () {
            if (hasRecovery()) {
              unawaited(controller.loadSaveStatus(refresh: true));
            }
          },
          cleanupStatus: controller.cleanupStatus,
          onRefresh: () {
            if (canAct()) unawaited(controller.refresh());
          },
          onLoadObservations: () {
            if (hasRecovery()) unawaited(controller.loadObservations());
          },
          onLoadTranscripts: () {
            if (hasRecovery()) unawaited(controller.loadTranscripts());
          },
          onRefreshTranscripts: () {
            if (hasRecovery()) {
              unawaited(controller.loadTranscripts(refresh: true));
            }
          },
          onDiscard: () {
            if (hasRecovery() && displayedRecovery?.practice != null) {
              unawaited(
                _confirmDiscard(
                  context,
                  controller,
                  displayedRecovery!.practice!,
                  canAct,
                ),
              );
            }
          },
          onConfirmAccount: () {
            if (canAct(requireApiOwner: false)) {
              unawaited(ref.read(accountControllerProvider.notifier).restore());
            }
          },
        );
      },
    );
  }
}

class PracticeRecoveryView extends StatelessWidget {
  const PracticeRecoveryView({
    super.key,
    this.busy = false,
    this.accountBusy = false,
    this.showAccountStatus = true,
    this.reviewEntryAvailable = true,
    this.recovery,
    this.page,
    this.events = const [],
    this.errorCode,
    this.observationErrorCode,
    this.transcripts,
    this.transcriptErrorCode,
    this.loadingTranscripts = false,
    this.savedCompletion,
    this.endRegistered = false,
    this.terminationCheck,
    this.saveStatusLoaded = false,
    this.loadingSaveStatus = false,
    this.saveStatusErrorCode,
    this.onOpenReview,
    this.onLoadSaveStatus,
    this.onRefreshSaveStatus,
    this.cleanupStatus = PreparationCleanupStatus.idle,
    this.onRefresh,
    this.onLoadObservations,
    this.onLoadTranscripts,
    this.onRefreshTranscripts,
    this.onConfirmAccount,
    this.onDiscard,
  });

  final bool busy, accountBusy, showAccountStatus;
  final bool reviewEntryAvailable;
  final PracticeRecovery? recovery;
  final ConnectionObservationPage? page;
  final List<ConnectionObservation> events;
  final String? errorCode;
  final String? observationErrorCode;
  final FinalTranscriptHistory? transcripts;
  final String? transcriptErrorCode;
  final bool loadingTranscripts;
  final PracticeCompletionSummary? savedCompletion;
  final bool endRegistered;
  final TerminationCheckSnapshot? terminationCheck;
  final bool saveStatusLoaded;
  final bool loadingSaveStatus;
  final String? saveStatusErrorCode;
  final VoidCallback? onOpenReview;
  final VoidCallback? onLoadSaveStatus;
  final VoidCallback? onRefreshSaveStatus;
  final PreparationCleanupStatus cleanupStatus;
  final VoidCallback? onRefresh;
  final VoidCallback? onLoadObservations;
  final VoidCallback? onLoadTranscripts;
  final VoidCallback? onRefreshTranscripts;
  final VoidCallback? onConfirmAccount;
  final VoidCallback? onDiscard;

  @override
  Widget build(BuildContext context) {
    final blocked = busy || accountBusy;
    final colors = Theme.of(context).colorScheme;
    final practice = recovery?.practice;
    final connection = recovery?.connection;
    final identityError =
        errorCode == 'account_changed' || errorCode == 'unauthorized';
    return LayoutBuilder(
      builder: (context, constraints) => DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Padding(
          padding: EdgeInsets.all(constraints.maxWidth < 360 ? 16 : 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionHeading(
                endRegistered ||
                        practice?.status == PracticeStatus.completed ||
                        savedCompletion?.status ==
                            PracticeCompletionStatus.sealed
                    ? '上次练习状态'
                    : '未结束练习',
              ),
              const SizedBox(height: 12),
              Text(
                '查看查询时的服务端记录，可刷新了解最新状态。仅查看不会重新连接或打开麦克风。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              if (accountBusy && showAccountStatus) ...[
                const StatusMessage('账号操作进行中，请稍候…', error: false),
                const SizedBox(height: 12),
              ],
              if (errorCode != null)
                StatusMessage(_errorMessage(errorCode!))
              else if (cleanupStatus == PreparationCleanupStatus.working)
                Semantics(liveRegion: true, child: const Text('正在清理准备…'))
              else if (cleanupStatus == PreparationCleanupStatus.succeeded)
                Semantics(
                  liveRegion: true,
                  child: const Text('这项准备已清理。请刷新查看当前状态。'),
                )
              else if (cleanupStatus == PreparationCleanupStatus.unconfirmed)
                const StatusMessage('清理结果尚未确认，请刷新核实。不会自动重试清理。')
              else if (cleanupStatus == PreparationCleanupStatus.refused)
                const StatusMessage('准备状态可能已变化，暂不能安全清理。请刷新后重新确认。')
              else if (busy && recovery == null)
                Semantics(liveRegion: true, child: const Text('正在读取状态…'))
              else if (recovery == null)
                const Text('查看是否有尚未结束的练习。')
              else if (practice == null)
                Semantics(liveRegion: true, child: const Text('没有未结束的练习'))
              else ...[
                if (practice.configuration.topic case final topic?) ...[
                  Text(topic.title),
                  const SizedBox(height: 8),
                ],
                Text(
                  '服务器记录：${savedCompletion == null && endRegistered ? '已登记结束' : _practiceLabel(savedCompletion?.status == PracticeCompletionStatus.sealed
                            ? PracticeStatus.completed
                            : savedCompletion?.status == PracticeCompletionStatus.ending
                            ? PracticeStatus.ending
                            : practice.status)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  '登记于 ${_date(practice.createdAt)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (connection != null) ...[
                  const SizedBox(height: 16),
                  Text('连接记录：${_connectionLabel(connection.status)}'),
                  const SizedBox(height: 8),
                  if (connection.terminationStatus ==
                      TerminationStatus.unknown) ...[
                    const Text('远端是否结束尚未确认'),
                    const SizedBox(height: 8),
                    const Text('本地关闭或业务租约到期，都不能确认远端连接和费用已结束。'),
                  ] else
                    Text(
                      connection.terminationStatus ==
                              TerminationStatus.notStarted
                          ? '服务端记录：尚未开始远端媒体。'
                          : '服务端已记录远端结束确认。',
                    ),
                  const SizedBox(height: 16),
                  const Text('查看记录不会接管或关闭这条连接。'),
                  if (page != null || observationErrorCode != null) ...[
                    const Divider(height: 32),
                    const Text('客户端连接记录'),
                    const SizedBox(height: 8),
                    Text(
                      '来自客户端上报，可能有缺漏；不能用于确认远端结束或费用。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (page != null && events.isEmpty) ...[
                      const SizedBox(height: 12),
                      const Text('尚无已保存的客户端记录。'),
                    ],
                    for (final event in events)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_eventLabel(event.code)),
                            const SizedBox(height: 4),
                            Text(
                              '服务端收到于 ${_date(event.receivedAt)}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    if (page != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        '已查看 ${events.length} 条，本次查询共 ${page!.totalEvents} 条。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                  if (observationErrorCode != null)
                    StatusMessage(_errorMessage(observationErrorCode!)),
                  if (busy && !loadingTranscripts && !loadingSaveStatus) ...[
                    const SizedBox(height: 12),
                    Semantics(liveRegion: true, child: const Text('正在读取连接记录…')),
                  ],
                  if (page == null || page!.hasMore) ...[
                    const SizedBox(height: 16),
                    OutlinedButton(
                      onPressed: blocked ? null : onLoadObservations,
                      child: Text(
                        observationErrorCode != null
                            ? '重试读取记录'
                            : page == null
                            ? '查看连接记录'
                            : '查看更多记录',
                      ),
                    ),
                  ],
                  if (practice.stateReason == 'content_deleted') ...[
                    const Divider(height: 32),
                    const Text('内容已删除，原连接与用量仍待核对。'),
                  ] else ...[
                    const Divider(height: 32),
                    PracticeSaveStatusView(
                      loaded: saveStatusLoaded,
                      busy: loadingSaveStatus,
                      completion: savedCompletion,
                      terminationCheck: terminationCheck,
                      terminationStatus: connection.terminationStatus,
                      errorCode: saveStatusErrorCode,
                      onLoad: blocked ? null : onLoadSaveStatus,
                      onRefresh: blocked ? null : onRefreshSaveStatus,
                    ),
                    if (!busy &&
                        reviewEntryAvailable &&
                        saveStatusLoaded &&
                        errorCode == null &&
                        saveStatusErrorCode == null &&
                        savedCompletion?.status ==
                            PracticeCompletionStatus.sealed &&
                        savedCompletion?.scope.sessionId == practice.id) ...[
                      const SizedBox(height: 16),
                      OutlinedButton(
                        onPressed: blocked ? null : onOpenReview,
                        child: const Text('查看复盘'),
                      ),
                    ],
                    const Divider(height: 32),
                    FinalTranscriptReadView(
                      history: transcripts,
                      busy: loadingTranscripts,
                      errorCode: transcriptErrorCode,
                      onLoad: blocked ? null : onLoadTranscripts,
                      onRefresh: blocked ? null : onRefreshTranscripts,
                    ),
                  ],
                ],
                if (!endRegistered &&
                    savedCompletion == null &&
                    recovery!.canDiscardPreparation) ...[
                  const Divider(height: 32),
                  Text(
                    '可尝试清理未开始的准备，服务端会再次核验完整记录。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: blocked ? null : onDiscard,
                    child: const Text('清理未开始的准备'),
                  ),
                ],
              ],
              const SizedBox(height: 20),
              if (identityError)
                OutlinedButton(
                  onPressed: blocked ? null : onConfirmAccount,
                  child: const Text('重新确认账号'),
                )
              else
                OutlinedButton(
                  onPressed: blocked ? null : onRefresh,
                  child: Text(
                    recovery == null &&
                            errorCode == null &&
                            cleanupStatus == PreparationCleanupStatus.idle
                        ? '查看未结束练习'
                        : '刷新状态',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _errorMessage(String code) => switch (code) {
  'account_changed' => '当前账号已变化，请重新确认账号后查看。',
  'unauthorized' => '登录已失效，请重新确认账号。',
  'invalid_response' => '服务端状态响应异常，请刷新后重试。',
  'practice_not_found' || 'connection_not_found' => '这条记录已不可用，请刷新查看当前状态。',
  _ => '暂时无法读取记录，请检查网络后重试。当前登录仍保留。',
};

String _practiceLabel(PracticeStatus status) => switch (status) {
  PracticeStatus.created => '等待开始',
  PracticeStatus.connecting => '正在连接',
  PracticeStatus.active => '练习进行中',
  PracticeStatus.interrupted => '练习已中断',
  PracticeStatus.ending => '正在结束',
  PracticeStatus.completed => '练习已结束',
  PracticeStatus.cancelled => '准备已取消',
  PracticeStatus.failed => '练习未完成',
};

String _connectionLabel(ConnectionStatus status) => switch (status) {
  ConnectionStatus.preparing => '准备中',
  ConnectionStatus.negotiating => '正在交换连接信息',
  ConnectionStatus.configuring => '等待配置确认',
  ConnectionStatus.ready => '已就绪',
  ConnectionStatus.closing => '正在关闭',
  ConnectionStatus.unknown => '状态待核对',
  ConnectionStatus.closed => '已关闭',
  ConnectionStatus.failed => '连接失败',
};

String _eventLabel(String code) => switch (code) {
  'requesting_microphone' => '客户端准备麦克风',
  'negotiating' => '客户端开始连接',
  'transport_connected' => '客户端报告传输已连接',
  'configuration_confirmed' => '客户端报告配置已确认',
  'microphone_active' => '客户端报告麦克风已启用',
  'playback_waiting' => '客户端等待播放',
  'playback_blocked' => '客户端播放受限',
  'playback_playing' => '客户端报告正在播放',
  'playback_paused' => '客户端播放已暂停',
  'muted' => '客户端已静音',
  'unmuted' => '客户端已取消静音',
  'local_closed' => '客户端报告本地已关闭',
  _ => '客户端连接记录',
};

String _date(DateTime time) {
  final local = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

@Preview(
  name: '恢复 · 读取失败 · 浅色',
  size: Size(320, 700),
  wrapper: previewWithFonts,
)
Widget recoveryErrorPreview() => MaterialApp(
  theme: buildAppTheme(Brightness.light),
  home: const Scaffold(
    body: SingleChildScrollView(
      child: PracticeRecoveryView(errorCode: 'network_error'),
    ),
  ),
);

@Preview(
  name: '恢复 · 未查询 · 深色大字号',
  size: Size(320, 880),
  wrapper: previewWithFonts,
)
Widget recoveryIdlePreview() => MaterialApp(
  theme: buildAppTheme(Brightness.dark),
  home: const MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(2)),
    child: Scaffold(body: SingleChildScrollView(child: PracticeRecoveryView())),
  ),
);
