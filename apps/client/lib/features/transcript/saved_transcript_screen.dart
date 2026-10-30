import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/account_components.dart';
import '../account/account_controller.dart';
import '../practice/practice_models.dart';
import 'saved_transcript_controller.dart';
import 'saved_transcript_providers.dart';
import 'saved_transcript_view.dart';

class SavedTranscriptScreen extends ConsumerStatefulWidget {
  const SavedTranscriptScreen({
    super.key,
    required this.sessionId,
    this.reviewItemId,
    this.fromHistory = false,
  });
  final String sessionId;
  final String? reviewItemId;
  final bool fromHistory;
  @override
  ConsumerState<SavedTranscriptScreen> createState() =>
      _SavedTranscriptScreenState();
}

class _SavedTranscriptScreenState extends ConsumerState<SavedTranscriptScreen> {
  SavedTranscriptController? _started;
  bool _isCurrentPage() {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
    final p = GoRouter.of(context)
        .routeInformationProvider
        .value
        .uri
        .pathSegments;
    return p.length == (widget.reviewItemId == null ? 3 : 4) &&
        p[0] == 'practice' &&
        p[1].toLowerCase() == widget.sessionId.toLowerCase() &&
        p[2] == 'transcript' &&
        (widget.reviewItemId == null ||
            p[3].toLowerCase() == widget.reviewItemId!.toLowerCase());
  }

  void _back() {
    if (!_isCurrentPage() || ref.read(accountControllerProvider).busy) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(
        widget.fromHistory
            ? '/history/${widget.sessionId}'
            : '/practice/${widget.sessionId}/review',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final backLabel = widget.fromHistory ? '返回练习详情' : '返回复盘';
    final account = ref.watch(accountControllerProvider);
    if (!isPracticeUuid(widget.sessionId) ||
        (widget.reviewItemId != null &&
            !isPracticeUuid(widget.reviewItemId!))) {
      return SavedTranscriptView(
        state: SavedTranscriptState.unavailable,
        errorCode: 'invalid_source',
        onBack: () {
          if (_isCurrentPage() && !ref.read(accountControllerProvider).busy) {
            context.go('/account');
          }
        },
      );
    }
    if (account.phase != SessionPhase.signedIn) {
      final failed = account.phase == SessionPhase.unreachable;
      return AccountFrame(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageIntro(
              title: failed ? '暂时连接不上' : '正在恢复你的账号',
              description: '文字地址已保留。确认当前账号后再读取本次记录。',
            ),
            if (failed) ...[
              const SizedBox(height: 16),
              PrimaryAction(
                label: '重新连接',
                onPressed: () {
                  if (!_isCurrentPage()) return;
                  final current = ref.read(accountControllerProvider);
                  if (current.phase == SessionPhase.unreachable &&
                      !current.busy) {
                    unawaited(
                      ref.read(accountControllerProvider.notifier).restore(),
                    );
                  }
                },
              ),
            ],
            const SizedBox(height: 16),
            OutlinedButton(onPressed: _back, child: Text(backLabel)),
          ],
        ),
      );
    }
    final controller = ref.watch(
      savedTranscriptProvider((
        sessionId: widget.sessionId,
        reviewItemId: widget.reviewItemId,
      )),
    );
    if (controller == null) {
      return SavedTranscriptView(
        state: SavedTranscriptState.unavailable,
        onBack: _back,
        backLabel: backLabel,
      );
    }
    if (!identical(_started, controller)) {
      _started = controller;
      unawaited(
        Future<void>.microtask(() async {
          if (mounted && identical(_started, controller)) {
            await controller.refresh();
          }
        }),
      );
    }
    bool canAct({bool requireIdle = true}) {
      if (!_isCurrentPage()) return false;
      final current = ref.read(accountControllerProvider);
      return current.phase == SessionPhase.signedIn &&
          !current.busy &&
          current.session?.user.id == controller.accountId &&
          identical(
            controller,
            ref.read(
              savedTranscriptProvider((
                sessionId: widget.sessionId,
                reviewItemId: widget.reviewItemId,
              )),
            ),
          ) &&
          (!requireIdle || !controller.busy);
    }

    final displayedPage = controller.page;
    bool hasPage() =>
        canAct() &&
        displayedPage != null &&
        identical(controller.page, displayedPage);
    return SavedTranscriptView(
      state: controller.state,
      page: controller.page,
      busy: controller.busy,
      accountBusy: account.busy,
      errorCode: controller.errorCode,
      hasFocus: widget.reviewItemId != null,
      onBack: () {
        if (canAct(requireIdle: false)) _back();
      },
      backLabel: backLabel,
      onRefresh: () {
        if (canAct()) unawaited(controller.refresh());
      },
      onPrevious: () {
        if (hasPage()) unawaited(controller.previous());
      },
      onNext: () {
        if (hasPage()) unawaited(controller.next());
      },
      onFocus: () {
        if (hasPage()) unawaited(controller.focus());
      },
      onConfirmAccount: () {
        if (canAct()) {
          unawaited(ref.read(accountControllerProvider.notifier).restore());
        }
      },
    );
  }
}
