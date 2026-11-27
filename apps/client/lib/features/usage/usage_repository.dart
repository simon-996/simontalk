import '../../core/api_client.dart';
import '../practice/practice_models.dart';
import 'usage_models.dart';

final class UsageRepository {
  const UsageRepository(this.api, {required this.accountId});

  final ApiClient api;
  final String accountId;

  Future<AccountUsageSummary> readAccountUsage() async {
    if (!isPracticeUuid(accountId)) {
      throw const ApiException('invalid_source', '账号地址无效。');
    }
    final json = await api.request(
      'GET',
      '/v1/usage?include_assistance=true',
      accountId: accountId,
      maxResponseBytes: 65536,
    );
    try {
      return AccountUsageSummary.fromJson(json, accountId: accountId);
    } on FormatException {
      throw const ApiException('invalid_response', '用量响应异常。');
    }
  }

  Future<PracticeUsageSummary> readPracticeUsage(String sessionId) async {
    if (!isPracticeUuid(accountId) || !isPracticeUuid(sessionId)) {
      throw const ApiException('invalid_source', '练习地址无效。');
    }
    final normalized = sessionId.toLowerCase();
    final json = await api.request(
      'GET',
      '/v1/usage/practices/$normalized?include_assistance=true',
      accountId: accountId,
      maxResponseBytes: 65536,
    );
    try {
      return PracticeUsageSummary.fromJson(
        json,
        accountId: accountId,
        sessionId: normalized,
      );
    } on FormatException {
      throw const ApiException('invalid_response', '用量响应异常。');
    }
  }
}
