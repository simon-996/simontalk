import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'design/account_components.dart';
import 'design/app_theme.dart';
import 'features/account/account_controller.dart';
import 'features/account/auth_screen.dart';
import 'features/account/preferences_screen.dart';
import 'features/practice/practice_models.dart';
import 'features/practice/practice_entry_screen.dart';
import 'features/practice/saved_practice_status_screen.dart';
import 'features/history/history_screen.dart';
import 'features/history/deletion_screen.dart';
import 'features/review/review_screen.dart';
import 'features/transcript/saved_transcript_screen.dart';
import 'features/rehearsal/rehearsal_screen.dart';
import 'features/rehearsal/rehearsal_list_screen.dart';

bool _isReadingPath(String path) {
  if (path == '/history' ||
      path.startsWith('/history/') &&
          (path.split('/').length == 3 ||
              path.split('/').length == 4 &&
                  {'delete', 'rehearsals'}.contains(path.split('/').last))) {
    return true;
  }
  final p = path.split('/');
  return p.length >= 4 &&
      p.length <= 5 &&
      p[1] == 'practice' &&
      ((p.length == 4 &&
              {'review', 'rehearsal-target', 'save-status'}.contains(p[3])) ||
          p[3] == 'transcript' ||
          p.length == 5 && p[3] == 'rehearse');
}

bool _isValidReadingPath(String path) {
  if (path == '/history') return true;
  if (path.startsWith('/history/')) {
    return (path.split('/').length == 3 ||
            path.split('/').length == 4 &&
                {'delete', 'rehearsals'}.contains(path.split('/').last)) &&
        isPracticeUuid(path.split('/')[2]);
  }
  final p = path.split('/');
  return _isReadingPath(path) &&
      isPracticeUuid(p[2]) &&
      (p.length == 4 || isPracticeUuid(p[4]));
}

final _routerProvider = Provider<GoRouter>((ref) {
  // The pushed reading route is independently deep-linkable. Include it in the
  // route information restored to the browser, while retaining its back stack.
  final previousUrlOption = GoRouter.optionURLReflectsImperativeAPIs;
  GoRouter.optionURLReflectsImperativeAPIs = true;
  final refresh = ValueNotifier(0);
  ref.listen(accountControllerProvider, (_, next) => refresh.value++);
  late final GoRouter router;
  router = GoRouter(
    initialLocation: '/loading',
    refreshListenable: refresh,
    redirect: (context, route) {
      final state = ref.read(accountControllerProvider);
      final path = route.uri.path;
      final readingPath = _isReadingPath(path);
      final validReading = _isValidReadingPath(path);
      final entryPath = [
        '/practice',
        '/practice/prepare',
        '/account',
      ].contains(path);
      // go_router restores an encoded history stack through its base URI.
      // Use this incoming history entry's reading address, independently of the
      // currently displayed page. Explicit go() carries a new navigation state.
      final incoming = router.routeInformationProvider.value;
      final readingHistory =
          incoming.state is Map && _isValidReadingPath(incoming.uri.path);
      final target = switch (state.phase) {
        SessionPhase.restoring =>
          validReading || readingHistory || entryPath ? path : '/loading',
        SessionPhase.unreachable =>
          validReading || readingHistory || entryPath ? path : '/connection',
        SessionPhase.signedOut =>
          ['/login', '/join', '/reset'].contains(path) ? path : '/login',
        SessionPhase.signedIn =>
          readingPath || readingHistory
              ? path
              : state.session!.preferences.difficulty == null
              ? '/setup'
              : entryPath
              ? path
              : '/practice',
      };
      return target == path ? null : target;
    },
    routes: [
      GoRoute(
        path: '/practice/:sessionId/save-status',
        builder: (_, route) => SavedPracticeStatusScreen(
          key: ValueKey(route.uri.path),
          sessionId: route.pathParameters['sessionId']!,
        ),
      ),
      GoRoute(
        path: '/practice/:sessionId/rehearse/:itemId',
        builder: (_, route) => RehearsalScreen(
          key: ValueKey(route.uri.path),
          sessionId: route.pathParameters['sessionId']!,
          itemId: route.pathParameters['itemId']!,
        ),
      ),
      GoRoute(
        path: '/practice/:sessionId/rehearsal-target',
        builder: (_, route) => RehearsalScreen(
          key: ValueKey(route.uri.path),
          sessionId: route.pathParameters['sessionId']!,
        ),
      ),
      GoRoute(path: '/history', builder: (_, _) => const HistoryScreen()),
      GoRoute(
        path: '/history/:sessionId/rehearsals',
        builder: (_, route) => RehearsalListScreen(
          key: ValueKey(route.uri.path),
          sourceSessionId: route.pathParameters['sessionId']!,
        ),
      ),
      GoRoute(
        path: '/history/:sessionId/delete',
        builder: (_, route) => DeletionScreen(
          key: ValueKey(route.uri.path),
          sessionId: route.pathParameters['sessionId']!,
        ),
      ),
      GoRoute(
        path: '/history/:sessionId',
        builder: (_, route) => HistoryScreen(
          key: ValueKey(route.uri.path),
          sessionId: route.pathParameters['sessionId']!,
        ),
      ),
      GoRoute(
        path: '/practice',
        builder: (_, _) => const _SignedInPage(child: PracticeHomeScreen()),
      ),
      GoRoute(
        path: '/practice/prepare',
        builder: (_, _) =>
            const _SignedInPage(child: PracticePreparationScreen()),
      ),
      GoRoute(
        path: '/practice/:sessionId/transcript',
        builder: (_, route) => SavedTranscriptScreen(
          key: ValueKey(route.uri.path),
          sessionId: route.pathParameters['sessionId']!,
          fromHistory: route.uri.queryParameters['from'] == 'history',
        ),
      ),
      GoRoute(
        path: '/practice/:sessionId/transcript/:reviewItemId',
        builder: (_, route) => SavedTranscriptScreen(
          key: ValueKey(route.uri.path),
          sessionId: route.pathParameters['sessionId']!,
          reviewItemId: route.pathParameters['reviewItemId']!,
        ),
      ),
      GoRoute(
        path: '/practice/:sessionId/review',
        builder: (_, route) => ReviewScreen(
          key: ValueKey(route.pathParameters['sessionId']),
          sessionId: route.pathParameters['sessionId']!,
          fromHistory: route.uri.queryParameters['from'] == 'history',
        ),
      ),
      GoRoute(path: '/loading', builder: (_, _) => const _ConnectionScreen()),
      GoRoute(
        path: '/connection',
        builder: (_, _) => const _ConnectionScreen(failed: true),
      ),
      GoRoute(
        path: '/login',
        builder: (_, _) => const AuthScreen(mode: AuthMode.login),
      ),
      GoRoute(
        path: '/join',
        builder: (_, _) => const AuthScreen(
          key: ValueKey('register'),
          mode: AuthMode.register,
        ),
      ),
      GoRoute(
        path: '/reset',
        builder: (_, _) =>
            const AuthScreen(key: ValueKey('reset'), mode: AuthMode.reset),
      ),
      GoRoute(
        path: '/setup',
        builder: (_, _) => const PreferencesScreen(onboarding: true),
      ),
      GoRoute(
        path: '/account',
        builder: (_, _) => const _SignedInPage(child: PreferencesScreen()),
      ),
    ],
  );
  ref.onDispose(() {
    router.dispose();
    refresh.dispose();
    GoRouter.optionURLReflectsImperativeAPIs = previousUrlOption;
  });
  return router;
});

class _SignedInPage extends ConsumerWidget {
  const _SignedInPage({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(
      accountControllerProvider.select((state) => state.phase),
    );
    return phase == SessionPhase.signedIn
        ? child
        : _ConnectionScreen(failed: phase == SessionPhase.unreachable);
  }
}

class SimonTalkApp extends ConsumerWidget {
  const SimonTalkApp({super.key, this.builder});
  final TransitionBuilder? builder;
  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
    title: 'SimonTalk',
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(Brightness.light),
    darkTheme: buildAppTheme(Brightness.dark),
    routerConfig: ref.watch(_routerProvider),
    builder: builder,
  );
}

class _ConnectionScreen extends ConsumerWidget {
  const _ConnectionScreen({this.failed = false});
  final bool failed;
  @override
  Widget build(BuildContext context, WidgetRef ref) => AccountFrame(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageIntro(
          title: failed ? '暂时连接不上' : '正在恢复你的账号',
          description: failed
              ? '登录凭证仍保留在当前设备。网络恢复后，可以重新连接。'
              : '请稍候，正在确认登录和个人设置。',
        ),
        if (failed) ...[
          StatusMessage(
            ref.watch(accountControllerProvider).error ?? '服务暂时不可用。',
          ),
          PrimaryAction(
            label: '重新连接',
            onPressed: () =>
                ref.read(accountControllerProvider.notifier).restore(),
          ),
        ] else
          const Center(child: CircularProgressIndicator()),
      ],
    ),
  );
}
