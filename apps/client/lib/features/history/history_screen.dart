import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/account_components.dart';
import '../account/account_controller.dart';
import 'history_controller.dart';
import 'history_providers.dart';
import 'history_models.dart';
import 'history_view.dart';

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key, this.sessionId});
  final String? sessionId;
  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  HistoryController? _started;
  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/history');
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountControllerProvider);
    if (account.phase != SessionPhase.signedIn) {
      final failed = account.phase == SessionPhase.unreachable;
      return AccountFrame(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageIntro(
              title: failed ? '暂时连接不上' : '正在恢复你的账号',
              description: '记录地址已保留，确认当前账号后再读取。',
            ),
            if (failed)
              PrimaryAction(
                label: '重新连接',
                onPressed: () =>
                    ref.read(accountControllerProvider.notifier).restore(),
              ),
          ],
        ),
      );
    }
    final c = ref.watch(historyProvider(widget.sessionId));
    if (c != null && !identical(_started, c)) {
      _started = c;
      unawaited(
        Future<void>.microtask(() async {
          if (mounted && identical(_started, c)) await c.refresh();
        }),
      );
    }
    // Recheck at activation: an old widget callback may outlive its metadata.
    bool canNavigate() {
      final current = ref.read(accountControllerProvider);
      return c != null &&
          current.phase == SessionPhase.signedIn &&
          !current.busy &&
          current.session?.user.id == c.accountId &&
          !c.busy;
    }

    HistoryItem? currentItem() {
      if (!canNavigate()) return null;
      final item = c!.item;
      return item?.id == widget.sessionId?.toLowerCase() ? item : null;
    }

    return HistoryView(
      state: c?.state ?? HistoryState.unavailable,
      page: c?.page,
      item: c?.item,
      detail: widget.sessionId != null,
      busy: (c?.busy ?? false) || account.busy,
      errorCode: c?.errorCode ?? (c == null ? 'invalid_source' : null),
      pageNumber: c?.pageNumber ?? 1,
      canPrevious: c?.canPrevious ?? false,
      canNext: c?.canNext ?? false,
      onRefresh: c?.refresh,
      onPrevious: c?.previous,
      onNext: c?.next,
      onBack: _back,
      onOpen: (id) {
        if (canNavigate() &&
            (c!.page?.items.any((item) => item.id == id) ?? false)) {
          context.push('/history/$id');
        }
      },
      onPractice: () => context.go('/practice'),
      onAccount: () => context.push('/account'),
      onText: () {
        final item = currentItem();
        if (item?.isSealed == true) {
          context.push('/practice/${item!.id}/transcript?from=history');
        }
      },
      onReview: () {
        final item = currentItem();
        if (item?.isSealed == true) {
          context.push('/practice/${item!.id}/review?from=history');
        }
      },
      onDelete: () {
        final item = currentItem();
        if (item != null) context.push('/history/${item.id}/delete');
      },
      onSaveStatus: () {
        final item = currentItem();
        if (item != null &&
            context.mounted &&
            ModalRoute.of(context)?.isCurrent == true &&
            GoRouter.of(context).routeInformationProvider.value.uri.path ==
                '/history/${widget.sessionId}' &&
            identical(ref.read(historyProvider(widget.sessionId)), c)) {
          context.push('/practice/${item.id}/save-status');
        }
      },
      onSource: () {
        final item = currentItem();
        if (item?.kind == 'rehearsal' && item?.sourceSessionId != null) {
          context.push('/history/${item!.sourceSessionId}');
        }
      },
      onTarget: () {
        final item = currentItem();
        if (item?.kind == 'rehearsal' && item?.sourceSessionId != null) {
          context.push('/practice/${item!.id}/rehearsal-target');
        }
      },
      onRelated: () {
        final current = currentItem();
        if (current != null && current.kind == 'ordinary') {
          context.push('/history/${current.id}/rehearsals');
        }
      },
      onConfirmAccount: () =>
          ref.read(accountControllerProvider.notifier).restore(),
    );
  }
}
