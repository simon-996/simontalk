import '../../core/api_client.dart';
import '../practice/practice_models.dart';
import 'review_models.dart';

/// Owner identity is explicit for every read and write, including Web cookies.
final class ReviewRepository {
  const ReviewRepository(this.api, {required this.accountId});
  final ApiClient api;
  final String accountId;
  void _validate(ReviewTarget target, {String? key}) {
    if (accountId != target.accountId ||
        !isPracticeUuid(accountId) ||
        (key != null && !isPracticeUuid(key))) {
      throw const ApiException('invalid_request', '复盘请求范围无效。');
    }
  }

  String _path(ReviewTarget target) =>
      '/v1/practice-sessions/${target.sessionId}';
  Future<T> _parse<T>(
    Future<Map<String, dynamic>> request,
    T Function(Map<String, dynamic>) parser,
  ) async {
    final json = await request;
    try {
      return parser(json);
    } on FormatException {
      throw const ApiException('invalid_response', '复盘响应异常。');
    }
  }

  Future<ReviewInputBinding> createInput(
    ReviewTarget target, {
    required String key,
  }) {
    _validate(target, key: key);
    return _parse(
      api.request(
        'POST',
        '${_path(target)}/review-input',
        accountId: accountId,
        idempotencyKey: key,
        body: {
          'input_revision': target.inputRevision,
          'input_hash': target.practiceInputHash,
        },
      ),
      (json) => ReviewInputBinding.fromJson(json, target: target),
    );
  }

  Future<ReviewInputBinding> readInput(ReviewTarget target) {
    _validate(target);
    return _parse(
      api.request('GET', '${_path(target)}/review-input', accountId: accountId),
      (json) => ReviewInputBinding.fromJson(json, target: target),
    );
  }

  Future<ReviewJobSnapshot> createJob(
    ReviewInputBinding input, {
    required String key,
  }) {
    _validate(input.target, key: key);
    return _parse(
      api.request(
        'POST',
        '${_path(input.target)}/review',
        accountId: accountId,
        idempotencyKey: key,
        body: input.toJobRequestJson(),
      ),
      (json) => ReviewJobSnapshot.fromJson(json, input: input),
    );
  }

  Future<ReviewJobSnapshot> readJob(ReviewInputBinding input) {
    _validate(input.target);
    return _parse(
      api.request('GET', '${_path(input.target)}/review', accountId: accountId),
      (json) => ReviewJobSnapshot.fromJson(json, input: input),
    );
  }

  Future<ReviewJobSnapshot> retryJob(
    ReviewInputBinding input, {
    required String jobId,
    required int expectedAttempts,
    required String key,
  }) {
    _validate(input.target, key: key);
    if (!isPracticeUuid(jobId) ||
        expectedAttempts < 0 ||
        expectedAttempts > 3) {
      throw const ApiException('invalid_request', '复盘重试范围无效。');
    }
    return _parse(
      api.request(
        'POST',
        '${_path(input.target)}/review/retry',
        accountId: accountId,
        idempotencyKey: key,
        body: {'job_id': jobId, 'expected_attempts': expectedAttempts},
      ),
      (json) => ReviewJobSnapshot.fromJson(json, input: input),
    );
  }
}
