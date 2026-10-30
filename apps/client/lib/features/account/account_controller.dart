import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/http_client_factory.dart';
import '../../core/token_store.dart';
import 'account_models.dart';
import 'account_repository.dart';

final accountRepositoryProvider = Provider<AccountRepository>((ref) {
  const configured = String.fromEnvironment('API_BASE_URL');
  final baseUrl = configured.isNotEmpty
      ? Uri.parse(configured)
      : kIsWeb
      ? Uri.base
      : Uri.parse('http://10.0.2.2:8000');
  final api = ApiClient(
    baseUrl: baseUrl,
    isWeb: kIsWeb,
    tokenStore: kIsWeb ? const CookieTokenStore() : const SecureTokenStore(),
    client: createHttpClient(),
  );
  ref.onDispose(api.close);
  return AccountRepository(api);
});

enum SessionPhase { restoring, signedOut, signedIn, unreachable }

class AccountState {
  const AccountState({
    this.phase = SessionPhase.restoring,
    this.session,
    this.busy = false,
    this.error,
  });
  final SessionPhase phase;
  final AccountSession? session;
  final bool busy;
  final String? error;
}

final accountControllerProvider =
    NotifierProvider<AccountController, AccountState>(AccountController.new);

class AccountController extends Notifier<AccountState> {
  AccountRepository get _repository => ref.read(accountRepositoryProvider);

  @override
  AccountState build() {
    unawaited(Future.microtask(restore));
    return const AccountState();
  }

  Future<void> restore() => _restore();

  Future<void> _restore({bool accountChanged = false}) async {
    if (!ref.mounted) return;
    final repository = _repository;
    final pending = AccountState();
    state = pending;
    bool isCurrent() => ref.mounted && identical(state, pending);
    const changedMessage = '当前浏览器已切换账号，旧页面修改未提交。请确认当前身份后再操作。';
    try {
      final session = await repository.restore(stillCurrent: isCurrent);
      if (!isCurrent()) return;
      state = AccountState(
        phase: session == null ? SessionPhase.signedOut : SessionPhase.signedIn,
        session: session,
        error: accountChanged ? changedMessage : null,
      );
    } on Object catch (error) {
      if (!isCurrent()) return;
      state = AccountState(
        phase: SessionPhase.unreachable,
        error: accountChanged ? changedMessage : _message(error),
      );
    }
  }

  void clearError() {
    if (!ref.mounted || state.busy || state.error == null) return;
    state = AccountState(phase: state.phase, session: state.session);
  }

  Future<bool> authenticate(
    Future<AccountSession> Function(AccountRepository) action,
  ) async {
    if (!ref.mounted || state.busy) return false;
    final repository = _repository;
    final pending = AccountState(
      phase: state.phase,
      session: state.session,
      busy: true,
    );
    state = pending;
    bool isCurrent() =>
        ref.mounted &&
        identical(state, pending) &&
        identical(ref.read(accountRepositoryProvider), repository);
    try {
      final session = await action(repository.scopedTo(isCurrent));
      if (!isCurrent()) return false;
      state = AccountState(phase: SessionPhase.signedIn, session: session);
      return true;
    } on Object catch (error) {
      if (!isCurrent()) return false;
      state = AccountState(
        phase:
            error is ApiException &&
                {'session_pending', 'account_changed'}.contains(error.code)
            ? SessionPhase.unreachable
            : SessionPhase.signedOut,
        error: _message(error),
      );
      return false;
    }
  }

  Future<bool> save(AccountPreferences draft) async {
    if (state.busy || state.session == null) return false;
    final session = state.session!;
    final repository = _repository;
    final pending = AccountState(
      phase: SessionPhase.signedIn,
      session: session,
      busy: true,
    );
    state = pending;
    bool isCurrent() => ref.mounted && identical(state, pending);
    try {
      final preferences = await repository.savePreferences(draft);
      if (!isCurrent()) return false;
      state = AccountState(
        phase: SessionPhase.signedIn,
        session: AccountSession(session.user, preferences),
      );
      return true;
    } on ApiException catch (error) {
      if (!isCurrent()) return false;
      if (error.code == 'account_changed') {
        await _recoverChangedAccount();
        return false;
      }
      if (error.statusCode == 401) {
        await restore();
        return false;
      }
      var preferences = session.preferences;
      var message = error.message;
      if (error.code == 'preferences_conflict') {
        try {
          preferences = await repository.loadPreferences();
          if (!isCurrent()) return false;
        } on Object catch (refreshError) {
          if (!isCurrent()) return false;
          if (refreshError is ApiException &&
              refreshError.code == 'account_changed') {
            await _recoverChangedAccount();
            return false;
          }
          message = '另一台设备已修改设置，但最新设置暂时无法载入。请连接网络后重新保存，当前修改仍保留。';
        }
      }
      state = AccountState(
        phase: SessionPhase.signedIn,
        session: AccountSession(session.user, preferences),
        error: message,
      );
      return false;
    } on Object catch (error) {
      if (!isCurrent()) return false;
      state = AccountState(
        phase: SessionPhase.signedIn,
        session: session,
        error: _message(error),
      );
      return false;
    }
  }

  Future<bool> logout() async {
    if (state.busy) return false;
    final session = state.session;
    final repository = _repository;
    final pending = AccountState(
      phase: state.phase,
      session: session,
      busy: true,
    );
    state = pending;
    bool isCurrent() => ref.mounted && identical(state, pending);
    try {
      final revoked = await repository.logout();
      if (!isCurrent()) return false;
      state = AccountState(
        phase: SessionPhase.signedOut,
        error: revoked ? null : '已清除本机登录。服务端退出尚未确认，该会话最迟到期时失效。',
      );
      return true;
    } on Object catch (error) {
      if (!isCurrent()) return false;
      if (error is ApiException && error.code == 'account_changed') {
        await _recoverChangedAccount();
        return false;
      }
      state = AccountState(
        phase: SessionPhase.signedIn,
        session: session,
        error: '退出尚未确认，请连接网络后重试。当前登录仍保留。',
      );
      return false;
    }
  }

  Future<bool> resetPassword(String token, String password) async {
    if (!ref.mounted || state.busy) return false;
    final repository = _repository;
    final pending = AccountState(phase: SessionPhase.signedOut, busy: true);
    state = pending;
    bool isCurrent() =>
        ref.mounted &&
        identical(state, pending) &&
        identical(ref.read(accountRepositoryProvider), repository);
    try {
      await repository.scopedTo(isCurrent).resetPassword(token, password);
      if (!isCurrent()) return false;
      state = const AccountState(phase: SessionPhase.signedOut);
      return true;
    } on Object catch (error) {
      if (!isCurrent()) return false;
      state = AccountState(
        phase: error is ApiException && error.code == 'account_changed'
            ? SessionPhase.unreachable
            : SessionPhase.signedOut,
        error: _message(error),
      );
      return false;
    }
  }

  Future<void> _recoverChangedAccount() => _restore(accountChanged: true);

  String _message(Object error) =>
      error is ApiException ? error.message : '暂时无法完成操作，请重试；仍有问题时请联系维护者。';
}
