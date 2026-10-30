import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/api_client.dart';
import '../../core/http_client_factory.dart';
import '../../core/random_uuid.dart';
import 'review_models.dart';
import 'review_repository.dart';

enum PracticeReviewClientState {
  idle,
  working,
  notCreated,
  ready,
  failed,
  aborted,
}

enum _ActionKind { input, create, retry }

/// An uncertain write retains only its fixed identity, key and immutable body data.
final class _Action {
  _Action.input()
    : kind = _ActionKind.input,
      key = randomUuid(),
      input = null,
      jobId = null,
      expectedAttempts = null;
  _Action.create(this.input, this.key)
    : kind = _ActionKind.create,
      jobId = null,
      expectedAttempts = null;
  _Action.retry(ReviewJobSnapshot job)
    : kind = _ActionKind.retry,
      key = randomUuid(),
      input = job.input,
      jobId = job.id,
      expectedAttempts = job.attemptCount;
  final _ActionKind kind;
  final String key;
  final ReviewInputBinding? input;
  final String? jobId;
  final int? expectedAttempts;
}

/// Explicit owner-scoped review actions; constructing or listening is silent.
final class PracticeReviewClient extends ChangeNotifier {
  PracticeReviewClient({
    required ApiClient accountApi,
    required this.target,
    http.Client Function()? httpClientFactory,
    Duration Function()? elapsed,
  }) : _source = accountApi,
       _httpClientFactory = httpClientFactory ?? createHttpClient,
       _elapsed = elapsed ?? _clock();
  final ApiClient _source;
  final ReviewTarget target;
  final http.Client Function() _httpClientFactory;
  final Duration Function() _elapsed;
  PracticeReviewClientState _state = PracticeReviewClientState.idle;
  ReviewInputBinding? _input;
  ReviewJobSnapshot? _job;
  _Action? _pending;
  String? _error;
  bool _aborted = false, _disposed = false;
  bool _needsRead = false;
  Future<void>? _task;
  ApiClient? _active;
  void Function()? _cancel;
  String? _inputHash, _jobId, _resultHash;
  List<String>? _resultItemIds;
  ReviewJobStatus? _successStatus;
  int _maxAttempts = 0;
  static Duration Function() _clock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  bool _ownsAccount() {
    if (_aborted || _disposed) return false;
    if (_source.hasCurrentAccount(target.accountId)) return true;
    _error = 'account_changed';
    _abort();
    return false;
  }

  PracticeReviewClientState get state {
    _ownsAccount();
    return _state;
  }

  String? get errorCode {
    _ownsAccount();
    return _error;
  }

  ReviewInputBinding? get input => _ownsAccount() ? _input : null;
  ReviewJobSnapshot? get job => _ownsAccount() ? _job : null;
  bool get hasPendingAction => _ownsAccount() && _pending != null;
  bool get canRetryGeneration =>
      _ownsAccount() &&
      _task == null &&
      !_needsRead &&
      _pending == null &&
      (_job?.canRetryGeneration ?? false);

  Future<void> requestReview() {
    if (!_ownsAccount()) return Future.value();
    if (_task != null) return _task!;
    if (_needsRead || _pending != null || _jobId != null) return Future.value();
    _pending = _Action.input();
    return _start(readOnly: false);
  }

  Future<void> refresh() {
    if (!_ownsAccount()) return Future.value();
    if (_task != null) return _task!;
    return _start(readOnly: true);
  }

  Future<void> retryPending() {
    if (!_ownsAccount()) return Future.value();
    if (_task != null) return _task!;
    if (_needsRead || _pending == null) return Future.value();
    return _start(readOnly: false);
  }

  Future<void> retryGeneration() {
    if (!_ownsAccount()) return Future.value();
    if (_task != null) return _task!;
    if (_needsRead || !canRetryGeneration) return Future.value();
    _pending = _Action.retry(_job!);
    return _start(readOnly: false);
  }

  Future<void> _start({required bool readOnly}) {
    final complete = Completer<void>();
    _task = complete.future;
    final cutoff = _elapsed() + const Duration(seconds: 8);
    _state = PracticeReviewClientState.working;
    _error = null;
    // No previous successful content is shown after a refresh or failed write.
    _input = null;
    _job = null;
    notifyListeners();
    unawaited(
      Future<void>.microtask(() async {
        try {
          await _run(readOnly: readOnly, cutoff: cutoff);
        } finally {
          _task = null;
          if (!_disposed && !_aborted) notifyListeners();
          complete.complete();
        }
      }),
    );
    return complete.future;
  }

  void _check(Duration cutoff) {
    if (!_ownsAccount()) throw const ApiException('cancelled', '复盘操作已停止。');
    if (_elapsed() >= cutoff) {
      throw const ApiException('review_timeout', '复盘请求超时。');
    }
  }

  Future<void> _run({required bool readOnly, required Duration cutoff}) async {
    ApiClient? api;
    Timer? timer;
    try {
      _check(cutoff);
      api = _source.forkForAccount(
        accountId: target.accountId,
        client: _httpClientFactory(),
      );
      _active = api;
      final cancelled = Completer<void>();
      _cancel = () {
        if (!cancelled.isCompleted) {
          cancelled.completeError(const ApiException('cancelled', '复盘操作已停止。'));
        }
      };
      final deadline = Completer<void>();
      timer = Timer(
        cutoff - _elapsed(),
        () => deadline.completeError(
          const ApiException('review_timeout', '复盘请求超时。'),
        ),
      );
      final repository = ReviewRepository(api, accountId: target.accountId);
      await Future.any<void>([
        _drive(repository, readOnly: readOnly, cutoff: cutoff),
        cancelled.future,
        deadline.future,
      ]);
      _check(cutoff);
      _error = null;
    } on Object catch (error) {
      if (_disposed || _aborted) return;
      _input = null;
      _job = null;
      if (!_source.hasCurrentAccount(target.accountId) ||
          (error is ApiException && error.code == 'account_changed')) {
        _error = 'account_changed';
        _abort();
      } else if (error is ApiException &&
          (error.statusCode == 401 || _fatal.contains(error.code))) {
        _error = error.statusCode == 401 ? 'unauthorized' : error.code;
        _abort();
      } else {
        if (error is ApiException &&
            error.statusCode == 409 &&
            {
              'review_retry_changed',
              'idempotency_conflict',
            }.contains(error.code)) {
          _pending = null;
          _needsRead = true;
        }
        _state = PracticeReviewClientState.failed;
        _error = error is ApiException && _safe.contains(error.code)
            ? error.code
            : 'review_failed';
      }
    } finally {
      timer?.cancel();
      _cancel = null;
      _active = null;
      api?.close();
    }
  }

  Future<void> _drive(
    ReviewRepository repository, {
    required bool readOnly,
    required Duration cutoff,
  }) async {
    if (readOnly) {
      ReviewInputBinding binding;
      try {
        _check(cutoff);
        binding = await repository.readInput(target);
        _check(cutoff);
        _acceptInput(binding);
      } on ApiException catch (error) {
        _check(cutoff);
        if (error.statusCode == 404 && error.code == 'review_input_not_found') {
          _needsRead = false;
          _state = PracticeReviewClientState.notCreated;
          return;
        }
        rethrow;
      }
      try {
        _check(cutoff);
        final next = await repository.readJob(binding);
        _check(cutoff);
        _acceptJob(next);
      } on ApiException catch (error) {
        _check(cutoff);
        if (error.statusCode == 404 && error.code == 'review_job_not_found') {
          _needsRead = false;
          _state = PracticeReviewClientState.notCreated;
          return;
        }
        rethrow;
      }
      _needsRead = false;
      return;
    }
    while (_pending != null) {
      _check(cutoff);
      final action = _pending!;
      if (action.kind == _ActionKind.input) {
        final binding = await repository.createInput(target, key: action.key);
        _check(cutoff);
        _acceptInput(binding);
        _pending = _Action.create(binding, action.key);
      } else {
        final next = action.kind == _ActionKind.create
            ? await repository.createJob(action.input!, key: action.key)
            : await repository.retryJob(
                action.input!,
                jobId: action.jobId!,
                expectedAttempts: action.expectedAttempts!,
                key: action.key,
              );
        _check(cutoff);
        _acceptJob(next);
        _pending = null;
      }
    }
  }

  void _acceptInput(ReviewInputBinding next) {
    if (_inputHash != null && _inputHash != next.reviewInputHash) {
      throw const ApiException('review_input_changed', '复盘输入响应异常。');
    }
    _inputHash = next.reviewInputHash;
    _input = next;
  }

  void _acceptJob(ReviewJobSnapshot next) {
    if (next.status == ReviewJobStatus.invalidated) {
      throw const ApiException('review_input_invalid', '复盘来源已失效。');
    }
    if ((_jobId != null && _jobId != next.id) ||
        next.attemptCount < _maxAttempts ||
        (_inputHash != null && _inputHash != next.input.reviewInputHash)) {
      throw const ApiException('invalid_response', '复盘任务响应异常。');
    }
    if (_resultHash != null &&
        (next.status != _successStatus ||
            next.result?.resultHash != _resultHash ||
            !listEquals(
              next.result?.items.map((i) => i.id).toList(),
              _resultItemIds,
            ))) {
      throw const ApiException('invalid_response', '复盘结果响应异常。');
    }
    _acceptInput(next.input);
    _jobId = next.id;
    _maxAttempts = next.attemptCount;
    if (next.result != null) {
      _resultHash = next.result!.resultHash;
      _resultItemIds = List.unmodifiable(next.result!.items.map((i) => i.id));
      _successStatus = next.status;
    }
    _job = next;
    _state = PracticeReviewClientState.ready;
  }

  static const _fatal = {
    'unauthorized',
    'account_changed',
    'practice_not_found',
    'connection_not_found',
    'completion_not_found',
    'completion_not_sealed',
    'review_input_changed',
    'review_input_invalid',
    'review_result_invalid',
    'source_invalidated',
  };
  static const _safe = {
    'network_error',
    'review_timeout',
    'invalid_response',
    'csrf_invalid',
    'origin_forbidden',
    'review_input_not_found',
    'review_job_not_found',
    'review_input_limit_exceeded',
    'idempotency_conflict',
    'review_retry_changed',
    'rate_limited',
    'service_unavailable',
  };
  void _abort() {
    if (_aborted) return;
    _aborted = true;
    _state = PracticeReviewClientState.aborted;
    _pending = null;
    _input = null;
    _job = null;
    _inputHash = null;
    _jobId = null;
    _resultHash = null;
    _resultItemIds = null;
    _successStatus = null;
    _maxAttempts = 0;
    _cancel?.call();
    _active?.close();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _abort();
    super.dispose();
  }
}
