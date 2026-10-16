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
  });

  final Uri baseUrl;
  final bool isWeb;
  final TokenStore tokenStore;
  final http.Client _client;
  final Duration timeout;
  String? _csrf;
  String? expectedAccountId;

  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final mutating = method != 'GET';
    if (isWeb && mutating && _csrf == null) {
      final response = await request('GET', '/v1/auth/csrf');
      _csrf = response['csrf_token'] as String?;
      if (_csrf == null || _csrf!.isEmpty) {
        throw const ApiException('invalid_response', '服务响应异常，请稍后重试。');
      }
    }
    final headers = <String, String>{'Accept': 'application/json'};
    if (expectedAccountId != null &&
        (path == '/v1/me/preferences' || path == '/v1/auth/logout')) {
      headers['X-Account-ID'] = expectedAccountId!;
    }
    if (body != null) headers['Content-Type'] = 'application/json';
    if (isWeb && mutating) headers['X-CSRF-Token'] = _csrf!;
    if (!isWeb) {
      final token = await tokenStore.read();
      if (token != null) headers['Authorization'] = 'Bearer $token';
    }
    try {
      final request = http.Request(method, baseUrl.resolve(path));
      request.headers.addAll(headers);
      if (body != null) request.body = jsonEncode(body);
      final response = await (() async => http.Response.fromStream(
        await _client.send(request),
      ))().timeout(timeout);
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
    }
  }

  void close() => _client.close();

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
    _ => '服务暂时不可用，请稍后重试。',
  };
}
