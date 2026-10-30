import '../../core/api_client.dart';
import '../conversation/conversation_models.dart';
import '../practice/practice_completion_models.dart';
import '../practice/practice_models.dart';
import '../review/review_models.dart';
import 'saved_transcript_models.dart';

/// All requests retain the explicit owner header, including cookie based Web.
final class SavedTranscriptRepository {
  const SavedTranscriptRepository(
    this.api, {
    required this.accountId,
    required this.sessionId,
  });
  final ApiClient api;
  final String accountId, sessionId;
  void _validate() {
    if (!isPracticeUuid(accountId) || !isPracticeUuid(sessionId)) {
      throw const ApiException('invalid_source', '练习地址无效。');
    }
  }

  Future<PracticeCompletionSummary> readCompletion() async {
    _validate();
    final j = await api.request(
      'GET',
      '/v1/practice-sessions/$sessionId/completion',
      accountId: accountId,
      maxResponseBytes: savedTranscriptMaxBytes,
    );
    try {
      String id(dynamic x) {
        if (x is! String || !isPracticeUuid(x)) throw const FormatException();
        return x.toLowerCase();
      }

      if (id(j['account_id']) != accountId ||
          id(j['session_id']) != sessionId ||
          j['epoch'] is! int) {
        throw const FormatException();
      }
      return PracticeCompletionSummary.fromJson(
        j,
        scope: ConversationScope(
          accountId: accountId,
          sessionId: sessionId,
          connectionId: id(j['origin_connection_id']),
          clientInstanceId: id(j['client_instance_id']),
          epoch: j['epoch'] as int,
        ),
      );
    } on FormatException {
      throw const ApiException('invalid_response', '来源响应异常。');
    }
  }

  Future<SavedTranscriptPage> readPage(
    ReviewTarget target, {
    int? offset,
    String? reviewItemId,
  }) async {
    _validate();
    if (target.accountId != accountId ||
        target.sessionId != sessionId ||
        (offset != null && (offset < 0 || offset > 8192)) ||
        (reviewItemId != null && !isPracticeUuid(reviewItemId))) {
      throw const ApiException('invalid_source', '读取范围无效。');
    }
    final query = Uri(
      queryParameters: {
        'input_revision': '${target.inputRevision}',
        'input_hash': target.practiceInputHash,
        'limit': '16',
        if (offset != null) 'offset': '$offset',
        'review_item_id': ?reviewItemId,
      },
    ).query;
    final j = await api.request(
      'GET',
      '/v1/practice-sessions/$sessionId/saved-transcript?$query',
      accountId: accountId,
      maxResponseBytes: savedTranscriptMaxBytes,
    );
    try {
      return SavedTranscriptPage.fromJson(
        j,
        target: target,
        offset: offset,
        reviewItemId: reviewItemId,
      );
    } on FormatException {
      throw const ApiException('invalid_response', '已保存文字响应异常。');
    }
  }
}
