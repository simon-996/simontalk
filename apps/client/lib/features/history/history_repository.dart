import '../../core/api_client.dart';
import '../practice/practice_models.dart';
import 'history_models.dart';

final class HistoryRepository {
  const HistoryRepository(this.api, {required this.accountId});
  final ApiClient api;
  final String accountId;
  Future<Map<String, dynamic>> _get(String suffix) {
    if (!isPracticeUuid(accountId)) {
      throw const ApiException('invalid_source', '账号地址无效。');
    }
    return api.request(
      'GET',
      '/v1/practice-history$suffix',
      accountId: accountId,
      maxResponseBytes: 65536,
    );
  }

  Future<HistoryPage> readPage({String? cursor}) async {
    if (cursor != null && !RegExp(r'^[A-Za-z0-9_-]{1,256}$').hasMatch(cursor)) {
      throw const ApiException('invalid_source', '分页地址无效。');
    }
    final query = Uri(queryParameters: {'limit': '10', 'cursor': ?cursor})
        .query;
    final j = await _get('?$query');
    try {
      return HistoryPage.fromJson(j, accountId: accountId, cursor: cursor);
    } on FormatException {
      throw const ApiException('invalid_response', '记录响应异常。');
    }
  }

  Future<HistoryItem> readDetail(String id) async {
    if (!isPracticeUuid(id)) {
      throw const ApiException('invalid_source', '练习地址无效。');
    }
    final j = await _get('/$id');
    try {
      return HistoryItem.fromDetail(j, accountId: accountId, sessionId: id);
    } on FormatException {
      throw const ApiException('invalid_response', '记录响应异常。');
    }
  }
}
