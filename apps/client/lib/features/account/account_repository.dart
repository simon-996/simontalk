import '../../core/api_client.dart';
import 'account_models.dart';

class AccountRepository {
  AccountRepository(this.api) : _stillCurrent = null;
  AccountRepository._scoped(this.api, this._stillCurrent);
  final ApiClient api;
  final bool Function()? _stillCurrent;

  AccountRepository scopedTo(bool Function() stillCurrent) =>
      AccountRepository._scoped(
        api,
        () => (_stillCurrent?.call() ?? true) && stillCurrent(),
      );

  void _checkActive() {
    if (_stillCurrent?.call() == false) {
      throw const ApiException('account_changed', '当前操作已失效，请确认身份后再操作。');
    }
  }

  bool _isCurrentOwner(String? owner) =>
      (_stillCurrent?.call() ?? true) &&
      api.expectedAccountId == owner &&
      (owner == null || api.hasCurrentAccount(owner));

  void _checkIdentity(String? owner) {
    _checkActive();
    if (api.expectedAccountId != owner ||
        owner != null && !api.hasCurrentAccount(owner)) {
      throw const ApiException('account_changed', '当前账号已变化，请确认身份后再操作。');
    }
  }

  Future<AccountSession?> restore({bool Function()? stillCurrent}) async {
    var owner = api.expectedAccountId;
    void check() {
      if (stillCurrent?.call() == false) {
        throw const ApiException('account_changed', '当前恢复已失效，请确认身份后再操作。');
      }
      _checkIdentity(owner);
    }

    if (!api.isWeb) {
      final token = await api.tokenStore.read();
      check();
      if (token == null) return null;
    }
    try {
      final user = _user(await api.request('GET', '/v1/me'));
      check();
      api.expectedAccountId = user.id;
      owner = user.id;
      final preferences = await loadPreferences();
      check();
      return AccountSession(user, preferences);
    } on ApiException catch (error) {
      if (error.statusCode == 401) {
        check();
        await api.tokenStore.delete();
        check();
        api.expectedAccountId = null;
        return null;
      }
      rethrow;
    }
  }

  Future<AccountSession> login(String username, String password) =>
      _authenticate('/v1/auth/login', {
        'username': username.trim(),
        'password': password,
      });

  Future<AccountSession> register({
    required String inviteCode,
    required String username,
    required String password,
    required String displayName,
  }) => _authenticate('/v1/auth/register', {
    'invite_code': inviteCode.trim(),
    'username': username.trim(),
    'password': password,
    'display_name': displayName.trim(),
  });

  Future<AccountSession> _authenticate(
    String path,
    Map<String, dynamic> body,
  ) async {
    var owner = api.expectedAccountId;
    _checkIdentity(owner);
    final data = await api.request(
      'POST',
      path,
      body: {...body, 'platform': api.isWeb ? 'web' : 'mobile'},
      accountId: owner,
      stillCurrent: () => _isCurrentOwner(owner),
    );
    _checkIdentity(owner);
    final rawUser = data['user'];
    if (rawUser is! Map<String, dynamic>) {
      throw const ApiException('invalid_response', '账号数据异常，请稍后重试。');
    }
    final user = _user(rawUser);
    final token = data['access_token'];
    if (!api.isWeb && (token is! String || token.isEmpty)) {
      throw const ApiException('invalid_response', '服务响应异常，请稍后重试。');
    }
    api.expectedAccountId = user.id;
    owner = user.id;
    if (!api.isWeb) {
      await api.tokenStore.write(token as String);
      _checkIdentity(owner);
    }
    try {
      final preferences = await loadPreferences();
      _checkIdentity(owner);
      return AccountSession(user, preferences);
    } on ApiException {
      _checkIdentity(owner);
      // Authentication has already committed; recover rather than resubmit.
      throw const ApiException('session_pending', '账号已就绪，但设置暂时无法载入。请重新连接。');
    }
  }

  Future<AccountPreferences> loadPreferences() async => _preferences(
    await api.request(
      'GET',
      '/v1/me/preferences',
      stillCurrent: _stillCurrent,
      accountId: api.expectedAccountId,
    ),
  );
  Future<AccountPreferences> savePreferences(
    AccountPreferences preferences,
  ) async => _preferences(
    await api.request(
      'PATCH',
      '/v1/me/preferences',
      stillCurrent: _stillCurrent,
      accountId: api.expectedAccountId,
      body: preferences.toJson(),
    ),
  );

  Future<void> resetPassword(String token, String password) async {
    final owner = api.expectedAccountId;
    _checkIdentity(owner);
    await api.request(
      'POST',
      '/v1/auth/password-reset/confirm',
      stillCurrent: () => _isCurrentOwner(owner),
      body: {'reset_token': token.trim(), 'new_password': password},
    );
    _checkIdentity(owner);
  }

  /// Returns false if the mobile credential was cleared but remote revocation
  /// could not be confirmed. Browser cookies require a server response.
  Future<bool> logout() async {
    final owner = api.expectedAccountId;
    var revoked = true;
    try {
      await api.request('POST', '/v1/auth/logout', accountId: owner);
    } on ApiException catch (error) {
      if (api.isWeb || error.code == 'account_changed') rethrow;
      revoked = false;
    }
    _checkIdentity(owner);
    await api.tokenStore.delete();
    _checkIdentity(owner);
    api.expectedAccountId = null;
    return revoked;
  }

  static AccountUser _user(Map<String, dynamic> data) {
    try {
      return AccountUser.fromJson(data);
    } on Object {
      throw const ApiException('invalid_response', '账号数据异常，请稍后重试。');
    }
  }

  static AccountPreferences _preferences(Map<String, dynamic> data) {
    try {
      return AccountPreferences.fromJson(data);
    } on Object {
      throw const ApiException('invalid_response', '设置数据异常，请稍后重试。');
    }
  }
}
