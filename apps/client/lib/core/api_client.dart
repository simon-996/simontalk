import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'token_store.dart';

class ApiException implements Exception {
  const ApiException(this.code, this.message, {this.statusCode});
  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'ApiException($code)';
}

class ApiClient {
  ApiClient({
    required this.baseUrl,
    required this.isWeb,
    required this.tokenStore,
    required this._client,
    this.timeout = const Duration(seconds: 15),
    this._accountIdentity,
  });

  final Uri baseUrl;
  final bool isWeb;
  final TokenStore tokenStore;
  final http.Client _client;
  final Duration timeout;
  final String? Function()? _accountIdentity;
  final _pendingRequests = <Completer<void>>{};
  bool _closed = false;
  String? _csrf;
  String? expectedAccountId;

  bool hasCurrentAccount(String accountId) => _currentAccountId == accountId;

  String? get _currentAccountId => _closed
      ? null
      : _accountIdentity != null
      ? _accountIdentity()
      : expectedAccountId;

  /// Owns the supplied independent HTTP client while following this account scope.
  ApiClient forkForAccount({
    required String accountId,
    required http.Client client,
  }) => ApiClient(
    baseUrl: baseUrl,
    isWeb: isWeb,
    tokenStore: tokenStore,
    client: client,
    timeout: timeout,
    accountIdentity: () => _currentAccountId,
  )..expectedAccountId = accountId;

  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? accountId,
    String? idempotencyKey,
  }) async {
    void checkAccount() {
      if (accountId != null && _currentAccountId != accountId) {
        throw const ApiException('account_changed', '当前账号已变化，请确认身份后再操作。');
      }
    }

    checkAccount();
    final mutating = method != 'GET';
    if (isWeb && mutating && _csrf == null) {
      final response = await request('GET', '/v1/auth/csrf');
      _csrf = response['csrf_token'] as String?;
      if (_csrf == null || _csrf!.isEmpty) {
        throw const ApiException('invalid_response', '服务响应异常，请稍后重试。');
      }
    }
    checkAccount();
    final headers = <String, String>{'Accept': 'application/json'};
    if (accountId != null) {
      headers['X-Account-ID'] = accountId;
    } else if (expectedAccountId != null &&
        (path == '/v1/me/preferences' || path == '/v1/auth/logout')) {
      headers['X-Account-ID'] = expectedAccountId!;
    }
    if (idempotencyKey != null) headers['Idempotency-Key'] = idempotencyKey;
    if (body != null) headers['Content-Type'] = 'application/json';
    if (isWeb && mutating) headers['X-CSRF-Token'] = _csrf!;
    if (!isWeb) {
      final token = await tokenStore.read();
      if (token != null) headers['Authorization'] = 'Bearer $token';
    }
    checkAccount();
    final abort = Completer<void>();
    _pendingRequests.add(abort);
    try {
      final request = http.AbortableRequest(
        method,
        baseUrl.resolve(path),
        abortTrigger: abort.future,
      );
      request.headers.addAll(headers);
      if (body != null) request.body = jsonEncode(body);
      final response = await (() async => http.Response.fromStream(
        await _client.send(request),
      ))().timeout(timeout);
      checkAccount();
      if (response.statusCode == 204) return {};
      Map<String, dynamic> data;
      try {
        data =
            jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      } on Object {
        throw ApiException(
          'invalid_response',
          '服务响应异常，请稍后重试。',
          statusCode: response.statusCode,
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final code = data['code'] as String? ?? 'service_unavailable';
        if (code == 'csrf_invalid') _csrf = null;
        throw ApiException(
          code,
          _messageFor(code),
          statusCode: response.statusCode,
        );
      }
      return data;
    } on TimeoutException {
      throw const ApiException('network_error', '连接超时，请检查网络后重试。');
    } on http.ClientException {
      throw const ApiException('network_error', '暂时无法连接服务，请检查网络后重试。');
    } finally {
      // BrowserClient.close only covers requests still waiting for headers.
      // The per-request signal also aborts an unfinished response body.
      if (!abort.isCompleted) abort.complete();
      _pendingRequests.remove(abort);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final abort in _pendingRequests) {
      if (!abort.isCompleted) abort.complete();
    }
    _pendingRequests.clear();
    _client.close();
  }

  static String _messageFor(String code) => switch (code) {
    'invite_invalid' => '邀请码无效、已使用或已过期，请向邀请人确认。',
    'registration_failed' => '无法创建这个账号，请检查用户名和邀请码后重试。',
    'invalid_credentials' => '用户名或密码不正确，请重试。',
    'unauthorized' => '登录已失效，请重新登录。',
    'csrf_invalid' => '安全凭证已更新，请重新提交。',
    'origin_forbidden' => '当前访问地址未获允许，请联系维护者。',
    'preferences_conflict' => '另一台设备已修改设置。已载入最新设置，请重新选择并保存。',
    'account_changed' => '浏览器已切换账号，请重新确认身份后操作。',
    'reset_invalid' => '重设凭证无效、已使用或已过期，请联系维护者重新获取。',
    'validation_error' => '请检查填写内容后重试。',
    'rate_limited' => '操作太频繁，请稍后再试。',
    'realtime_unavailable' => '实时语音尚未就绪，暂时无法开始练习。',
    'practice_in_progress' ||
    'connection_in_progress' => '已有练习或连接尚未安全结束，请先处理当前练习。',
    'connection_lease_expired' => '连接租约已到期，请确认当前状态后重新准备。',
    'practice_configuration_changed' => '语音配置已更改，请重新准备练习。',
    _ => '服务暂时不可用，请稍后重试。',
  };
}
