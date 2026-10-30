import '../../core/api_client.dart';
import '../account/account_models.dart';
import '../practice/practice_models.dart';
import '../practice/practice_repository.dart';
import 'rehearsal_models.dart';

final class RehearsalRepository {
  const RehearsalRepository(
    this.api, {
    required this.accountId,
    required this.sessionId,
    this.itemId,
  });
  final ApiClient api;
  final String accountId, sessionId;
  final String? itemId;
  void _validate() {
    if (!isPracticeUuid(accountId) ||
        !isPracticeUuid(sessionId) ||
        itemId != null && !isPracticeUuid(itemId!)) {
      throw const ApiException('invalid_source', '重练地址无效。');
    }
  }

  T _parse<T>(T Function() read) {
    try {
      return read();
    } on Object {
      throw const ApiException('invalid_response', '重练响应异常。');
    }
  }

  Future<RehearsalTarget> load(void Function() check) async {
    _validate();
    var source = sessionId, item = itemId;
    if (item == null) {
      final j = await api.request(
        'GET',
        '/v1/practice-sessions/$sessionId',
        accountId: accountId,
        maxResponseBytes: 32768,
      );
      check();
      final binding = _parse(() {
        final source = rehearsalId(j['source_session_id']),
            item = rehearsalId(j['source_review_item_id']);
        rehearsalPractice(
          j,
          sourceSessionId: source,
          itemId: item,
          childId: sessionId,
        );
        return (source, item);
      });
      source = binding.$1;
      item = binding.$2;
    }
    check();
    final j = await api.request(
      'GET',
      itemId == null
          ? '/v1/practice-sessions/$sessionId/rehearsal-target'
          : '/v1/practice-sessions/$source/review-items/$item/rehearsal-target',
      accountId: accountId,
      maxResponseBytes: 65536,
    );
    check();
    return _parse(
      () => RehearsalTarget.fromJson(
        j,
        accountId: accountId,
        sourceSessionId: source,
        itemId: item!,
      ),
    );
  }

  Future<PracticePreparation> create(
    RehearsalTarget target,
    Difficulty difficulty,
    String key,
  ) async {
    _validate();
    if (itemId == null ||
        target.sourceSessionId != sessionId ||
        target.itemId != itemId ||
        !isPracticeUuid(key)) {
      throw const ApiException('invalid_source', '重练范围无效。');
    }
    final j = await api.request(
      'POST',
      '/v1/practice-sessions/$sessionId/review-items/$itemId/rehearsals',
      accountId: accountId,
      idempotencyKey: key,
      body: {
        'target_hash': target.targetHash,
        'difficulty_override': difficulty.name,
      },
      maxResponseBytes: 98304,
    );
    return _parse(
      () => readRehearsalPreparation(
        j,
        accountId: accountId,
        expected: target,
        difficulty: difficulty,
      ),
    );
  }

  Future<PracticePreparation> discard(PracticePreparation p) =>
      PracticeRepository(api, accountId: accountId).discardPreparation(p);
}
