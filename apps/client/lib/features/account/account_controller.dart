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

  Future<void> restore() async {
    state = const AccountState();
    try {
      final session = await _repository.restore();
      state = AccountState(
        phase: session == null ? SessionPhase.signedOut : SessionPhase.signedIn,
        session: session,
      );
    } on Object catch (error) {
      state = AccountState(
        phase: SessionPhase.unreachable,
        error: _message(error),
      );
    }
  }

  void clearError() =>
      state = AccountState(phase: state.phase, session: state.session);

  Future<bool> authenticate(
    Future<AccountSession> Function(AccountRepository) action,
  ) async {
    if (state.busy) return false;
    state = AccountState(
      phase: state.phase,
      session: state.session,
      busy: true,
    );
    try {
      final session = await action(_repository);
      state = AccountState(phase: SessionPhase.signedIn, session: session);
      return true;
    } on Object catch (error) {
      state = AccountState(
        phase: error is ApiException && error.code == 'session_pending'
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
    state = AccountState(
      phase: SessionPhase.signedIn,
      session: session,
      busy: true,
    );
    try {
      final preferences = await _repository.savePreferences(draft);
      state = AccountState(
        phase: SessionPhase.signedIn,
        session: AccountSession(session.user, preferences),
      );
      return true;
    } on ApiException catch (error) {
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
          preferences = await _repository.loadPreferences();
        } on Object catch (refreshError) {
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
    state = AccountState(phase: state.phase, session: session, busy: true);
    try {
      final revoked = await _repository.logout();
      state = AccountState(
        phase: SessionPhase.signedOut,
        error: revoked ? null : '已清除本机登录。服务端退出尚未确认，该会话最迟到期时失效。',
      );
      return true;
    } on Object catch (error) {
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
    if (state.busy) return false;
    state = const AccountState(phase: SessionPhase.signedOut, busy: true);
    try {
      await _repository.resetPassword(token, password);
      state = const AccountState(phase: SessionPhase.signedOut);
      return true;
    } on Object catch (error) {
      state = AccountState(
        phase: SessionPhase.signedOut,
        error: _message(error),
      );
      return false;
    }
  }

  Future<void> _recoverChangedAccount() async {
    await restore();
    state = AccountState(
      phase: state.phase,
      session: state.session,
      error: '当前浏览器已切换账号，旧页面修改未提交。请确认当前身份后再操作。',
    );
  }

  String _message(Object error) =>
      error is ApiException ? error.message : '暂时无法完成操作，请重试；仍有问题时请联系维护者。';
}
