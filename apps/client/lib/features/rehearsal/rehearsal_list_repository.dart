import '../../core/api_client.dart';
import '../practice/practice_models.dart';
import 'rehearsal_list_models.dart';

final class RehearsalListRepository {
  const RehearsalListRepository(
    this.api, {
    required this.accountId,
    required this.sourceSessionId,
  });
  final ApiClient api;
  final String accountId, sourceSessionId;
  Future<RehearsalListPage> read({RelatedRehearsal? before}) async {
    if (!isPracticeUuid(accountId) ||
        !isPracticeUuid(sourceSessionId) ||
        before != null && before.sourceSessionId != sourceSessionId) {
      throw const ApiException('invalid_source', '关联练习地址无效。');
    }
    final query = Uri(
      queryParameters: {'limit': '10', 'before_id': ?before?.id},
    ).query;
    final j = await api.request(
      'GET',
      '/v1/practice-sessions/$sourceSessionId/rehearsals?$query',
      accountId: accountId,
      maxResponseBytes: 32768,
    );
    try {
      return RehearsalListPage.fromJson(
        j,
        accountId: accountId,
        sourceSessionId: sourceSessionId,
        before: before,
      );
    } on FormatException {
      throw const ApiException('invalid_response', '关联练习响应异常。');
    }
  }
}
