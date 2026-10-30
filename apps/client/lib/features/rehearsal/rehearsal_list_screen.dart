import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/account_components.dart';
import '../account/account_controller.dart';
import 'rehearsal_list_controller.dart';
import 'rehearsal_list_providers.dart';
import 'rehearsal_list_view.dart';

class RehearsalListScreen extends ConsumerStatefulWidget {
  const RehearsalListScreen({super.key, required this.sourceSessionId});
  final String sourceSessionId;
  @override
  ConsumerState<RehearsalListScreen> createState() =>
      _RehearsalListScreenState();
}

class _RehearsalListScreenState extends ConsumerState<RehearsalListScreen> {
  RehearsalListController? _started;
  final _pageFocus = FocusNode(debugLabel: '关联重练当前页', skipTraversal: true);
  bool _isCurrentPage() {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
    final p = GoRouter.of(context)
        .routeInformationProvider
        .value
        .uri
        .pathSegments;
    return p.length == 3 &&
        p[0] == 'history' &&
        p[1].toLowerCase() == widget.sourceSessionId.toLowerCase() &&
        p[2] == 'rehearsals';
  }

  bool _canAct(RehearsalListController c, {bool requireIdle = true}) {
    if (!_isCurrentPage()) return false;
    final current = ref.read(accountControllerProvider);
    return current.phase == SessionPhase.signedIn &&
        !current.busy &&
        current.session?.user.id == c.accountId &&
        identical(c, ref.read(rehearsalListProvider(widget.sourceSessionId))) &&
        (!requireIdle || !c.busy);
  }

  void _back() {
    if (!_isCurrentPage() || ref.read(accountControllerProvider).busy) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/history/${widget.sourceSessionId}');
    }
  }

  Future<void> _move(
    RehearsalListController c,
    Future<void> Function() action,
  ) async {
    if (!_canAct(c)) return;
    final previous = c.page;
    await action();
    if (!_canAct(c) ||
        !identical(c, _started) ||
        c.page == null ||
        identical(c.page, previous) ||
        c.state != RehearsalListState.ready) {
      return;
    }
    final accepted = c.page;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_canAct(c) ||
          !identical(c, _started) ||
          !identical(c.page, accepted)) {
        return;
      }
      _pageFocus.requestFocus();
      final target = _pageFocus.context;
      if (target != null) {
        unawaited(Scrollable.ensureVisible(target));
      }
    });
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
              description: '关联重练地址已保留，确认当前账号后再读取。',
            ),
            if (failed)
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
            OutlinedButton(onPressed: _back, child: const Text('返回来源练习')),
          ],
        ),
      );
    }
    final c = ref.watch(rehearsalListProvider(widget.sourceSessionId));
    if (c != null && !identical(c, _started)) {
      _started = c;
      unawaited(
        Future<void>.microtask(() async {
          if (mounted && identical(c, _started)) {
            await c.refresh();
          }
        }),
      );
    }
    final displayedPage = c?.page;
    bool hasPage() =>
        c != null &&
        _canAct(c) &&
        displayedPage != null &&
        identical(c.page, displayedPage);
    return RehearsalListView(
      state: c?.state ?? RehearsalListState.unavailable,
      page: c?.page,
      pageNumber: c?.pageNumber ?? 1,
      errorCode: c?.errorCode ?? (c == null ? 'invalid_source' : null),
      busy: c?.busy ?? false,
      accountBusy: account.busy,
      canNext: c?.canNext ?? false,
      canPrevious: c?.canPrevious ?? false,
      pageFocus: _pageFocus,
      onRefresh: c == null ? null : () => _move(c, c.refresh),
      onNext: c == null
          ? null
          : () {
              if (hasPage()) unawaited(_move(c, c.next));
            },
      onPrevious: c == null
          ? null
          : () {
              if (hasPage()) unawaited(_move(c, c.previous));
            },
      onOpen: (id) {
        if (hasPage() && c!.canOpen(id)) {
          context.push('/history/$id');
        }
      },
      onBack: c == null
          ? _back
          : () {
              if (_canAct(c, requireIdle: false)) _back();
            },
      onConfirmAccount: c == null
          ? null
          : () {
              if (_canAct(c)) {
                unawaited(
                  ref.read(accountControllerProvider.notifier).restore(),
                );
              }
            },
    );
  }

  @override
  void dispose() {
    _pageFocus.dispose();
    super.dispose();
  }
}
