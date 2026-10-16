import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'design/account_components.dart';
import 'design/app_theme.dart';
import 'features/account/account_controller.dart';
import 'features/account/auth_screen.dart';
import 'features/account/preferences_screen.dart';

final _routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier(0);
  ref.listen(accountControllerProvider, (_, next) => refresh.value++);
  final router = GoRouter(
    initialLocation: '/loading',
    refreshListenable: refresh,
    redirect: (context, route) {
      final state = ref.read(accountControllerProvider);
      final path = route.uri.path;
      final target = switch (state.phase) {
        SessionPhase.restoring => '/loading',
        SessionPhase.unreachable => '/connection',
        SessionPhase.signedOut =>
          ['/login', '/join', '/reset'].contains(path) ? path : '/login',
        SessionPhase.signedIn =>
          state.session!.preferences.difficulty == null ? '/setup' : '/account',
      };
      return target == path ? null : target;
    },
    routes: [
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
      GoRoute(path: '/account', builder: (_, _) => const PreferencesScreen()),
    ],
  );
  ref.onDispose(router.dispose);
  ref.onDispose(refresh.dispose);
  return router;
});

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
