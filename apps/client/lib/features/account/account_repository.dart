import '../../core/api_client.dart';
import 'account_models.dart';

class AccountRepository {
  AccountRepository(this.api);
  final ApiClient api;

  Future<AccountSession?> restore() async {
    if (!api.isWeb && await api.tokenStore.read() == null) return null;
    try {
      final user = _user(await api.request('GET', '/v1/me'));
      api.expectedAccountId = user.id;
      return AccountSession(user, await loadPreferences());
    } on ApiException catch (error) {
      if (error.statusCode == 401) {
        await api.tokenStore.delete();
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
    final data = await api.request(
      'POST',
      path,
      body: {...body, 'platform': api.isWeb ? 'web' : 'mobile'},
    );
    final rawUser = data['user'];
    if (rawUser is! Map<String, dynamic>) {
      throw const ApiException('invalid_response', '账号数据异常，请稍后重试。');
    }
    final user = _user(rawUser);
    api.expectedAccountId = user.id;
    if (!api.isWeb) {
      final token = data['access_token'];
      if (token is! String || token.isEmpty) {
        throw const ApiException('invalid_response', '服务响应异常，请稍后重试。');
      }
      await api.tokenStore.write(token);
    }
    try {
      return AccountSession(user, await loadPreferences());
    } on ApiException {
      // Authentication has already committed. Recover the existing session
      // instead of inviting a second registration or consuming another invite.
      throw const ApiException('session_pending', '账号已就绪，但设置暂时无法载入。请重新连接。');
    }
  }

  Future<AccountPreferences> loadPreferences() async =>
      _preferences(await api.request('GET', '/v1/me/preferences'));
  Future<AccountPreferences> savePreferences(
    AccountPreferences preferences,
  ) async => _preferences(
    await api.request(
      'PATCH',
      '/v1/me/preferences',
      body: preferences.toJson(),
    ),
  );

  Future<void> resetPassword(String token, String password) async {
    await api.request(
      'POST',
      '/v1/auth/password-reset/confirm',
      body: {'reset_token': token.trim(), 'new_password': password},
    );
  }

  /// Returns false if the mobile credential was cleared but remote revocation
  /// could not be confirmed. Browser cookies require a server response.
  Future<bool> logout() async {
    var revoked = true;
    try {
      await api.request('POST', '/v1/auth/logout');
    } on ApiException catch (error) {
      if (api.isWeb || error.code == 'account_changed') rethrow;
      revoked = false;
    }
    await api.tokenStore.delete();
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
