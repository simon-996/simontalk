import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/api_client.dart';
import '../../core/http_client_factory.dart';
import '../conversation/conversation_models.dart';
import '../practice/practice_completion_models.dart';
import '../practice/practice_models.dart';
import 'practice_review_client.dart';
import 'review_models.dart';

enum ReviewPageState {
  idle,
  readingSource,
  readingReview,
  notSaved,
  saving,
  ready,
  failed,
  unavailable,
  aborted,
}

/// Reads the URL's owner-scoped source before delegating explicit review actions.
/// Source reads and review operations each own a separate eight-second deadline.
final class ReviewPageController extends ChangeNotifier {
  ReviewPageController({
    required ApiClient accountApi,
    required this.accountId,
    required this.sessionId,
    http.Client Function()? httpClientFactory,
    Duration Function()? elapsed,
  }) : _source = accountApi,
       _httpClientFactory = httpClientFactory ?? createHttpClient,
       _elapsed = elapsed ?? _clock();

  final ApiClient _source;
  final String accountId, sessionId;
  final http.Client Function() _httpClientFactory;
  final Duration Function() _elapsed;
  ReviewPageState _state = ReviewPageState.idle;
  PracticeCompletionSummary? _completion;
  PracticeReviewClient? _review;
  bool _confirmed = false, _disposed = false, _aborted = false;
  String? _error;
  Future<void>? _task;
  ApiClient? _active;
  void Function()? _cancel;

  static Duration Function() _clock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsed;
  }

  bool _ownsAccount() {
    if (_disposed || _aborted) return false;
    if (_source.hasCurrentAccount(accountId)) return true;
    _error = 'account_changed';
    _abort();
    return false;
  }

  ReviewPageState get state {
    _ownsAccount();
    return _state;
  }

  bool get busy => _ownsAccount() && _task != null;
  String? get errorCode {
    _ownsAccount();
    return _error ?? (_confirmed ? _review?.errorCode : null);
  }

  PracticeCompletionSummary? get completion =>
      _ownsAccount() &&
          _confirmed &&
          !(_task != null && _state != ReviewPageState.readingReview)
      ? _completion
      : null;
  ReviewJobSnapshot? get job =>
      _ownsAccount() && _confirmed && _task == null ? _review?.job : null;
  bool get hasPendingAction =>
      _ownsAccount() &&
      _confirmed &&
      _task == null &&
      (_review?.hasPendingAction ?? false);
  bool get canRequestReview =>
      _ownsAccount() &&
      _confirmed &&
      _task == null &&
      _review?.state == PracticeReviewClientState.notCreated &&
      !(_review?.hasPendingAction ?? false);
  bool get canRetryGeneration =>
      _ownsAccount() &&
      _confirmed &&
      _task == null &&
      (_review?.canRetryGeneration ?? false);

  bool get canReadSavedText =>
      _ownsAccount() &&
      _confirmed &&
      _task == null &&
      _completion?.status == PracticeCompletionStatus.sealed;
  bool canLocateItem(String id) =>
      canReadSavedText &&
      job?.status == ReviewJobStatus.succeeded &&
      (job?.result?.items.any((item) => item.id == id) ?? false);

  Future<void> refresh() {
    if (!_ownsAccount()) return Future.value();
    if (_task != null) return _task!;
    if (!isPracticeUuid(accountId) || !isPracticeUuid(sessionId)) {
      _clearReview();
      _completion = null;
      _confirmed = false;
      _error = 'invalid_source';
      _state = ReviewPageState.unavailable;
      notifyListeners();
      return Future.value();
    }
    return _start(() async {
      _confirmed = false;
      _completion = null;
      _error = null;
      _state = ReviewPageState.readingSource;
      notifyListeners();
      try {
        final summary = await _readSource();
        if (!_ownsAccount()) return;
        _completion = summary;
        _confirmed = true;
        if (summary.status != PracticeCompletionStatus.sealed) {
          _clearReview();
          _state = ReviewPageState.saving;
          return;
        }
        final target = ReviewTarget.fromCompletion(summary);
        if (_review?.target != target) {
          _clearReview();
          _review = PracticeReviewClient(
            accountApi: _source,
            target: target,
            httpClientFactory: _httpClientFactory,
            elapsed: _elapsed,
          );
        }
        _state = ReviewPageState.readingReview;
        notifyListeners();
        await _review!.refresh();
        if (_ownsAccount()) _acceptReview();
      } on Object catch (error) {
        if (!_ownsAccount()) return;
        _confirmed = false;
        _completion = null;
        final api = error is ApiException ? error : null;
        _error = api?.code ?? 'invalid_response';
        if (api?.statusCode == 401 || api?.code == 'account_changed') {
          _error = api?.statusCode == 401 ? 'unauthorized' : 'account_changed';
          _abort();
        } else if (api?.statusCode == 404 &&
            api?.code == 'completion_not_found') {
          _clearReview();
          _error = null;
          _state = ReviewPageState.notSaved;
        } else if (api?.statusCode == 404 ||
            api?.code == 'source_invalidated') {
          _clearReview();
          _state = ReviewPageState.unavailable;
        } else {
          // A network failure can be reconciled with the same pending action
          // after the original sealed target is confirmed again.
          if (!{
            'network_error',
            'source_timeout',
            'service_unavailable',
            'rate_limited',
          }.contains(api?.code)) {
            _clearReview();
          }
          _state = ReviewPageState.failed;
        }
      }
    });
  }

  Future<void> requestReview() =>
      _delegate(() => _review!.requestReview(), allowed: canRequestReview);
  Future<void> retryGeneration() =>
      _delegate(() => _review!.retryGeneration(), allowed: canRetryGeneration);
  Future<void> retryPending() =>
      _delegate(() => _review!.retryPending(), allowed: hasPendingAction);

  Future<void> _delegate(
    Future<void> Function() action, {
    required bool allowed,
  }) {
    if (!_ownsAccount()) return Future.value();
    if (_task != null) return _task!;
    if (!_confirmed || !allowed || _review == null) return Future.value();
    return _start(() async {
      _state = ReviewPageState.readingReview;
      _error = null;
      final work = action();
      notifyListeners();
      await work;
      if (_ownsAccount()) _acceptReview();
    });
  }

  void _acceptReview() {
    if (_review!.state == PracticeReviewClientState.aborted) {
      _error = _review!.errorCode;
      _confirmed = false;
      _completion = null;
      _clearReview();
      _state = ReviewPageState.unavailable;
    } else {
      _state = _review!.state == PracticeReviewClientState.failed
          ? ReviewPageState.failed
          : ReviewPageState.ready;
    }
  }

  Future<void> _start(Future<void> Function() action) {
    final done = Completer<void>();
    _task = done.future;
    unawaited(
      Future<void>.microtask(() async {
        try {
          if (_ownsAccount()) await action();
        } finally {
          _task = null;
          if (!_disposed) notifyListeners();
          done.complete();
        }
      }),
    );
    return done.future;
  }

  Future<PracticeCompletionSummary> _readSource() async {
    final cutoff = _elapsed() + const Duration(seconds: 8);
    void check() {
      if (!_ownsAccount()) throw const ApiException('cancelled', '读取已停止。');
      if (_elapsed() >= cutoff) {
        throw const ApiException('source_timeout', '来源读取超时。');
      }
    }

    ApiClient? api;
    Timer? timer;
    try {
      check();
      api = _source.forkForAccount(
        accountId: accountId,
        client: _httpClientFactory(),
      );
      _active = api;
      final cancelled = Completer<PracticeCompletionSummary>();
      _cancel = () {
        if (!cancelled.isCompleted) {
          cancelled.completeError(const ApiException('cancelled', '读取已停止。'));
        }
      };
      final deadline = Completer<PracticeCompletionSummary>();
      timer = Timer(
        cutoff - _elapsed(),
        () => deadline.completeError(
          const ApiException('source_timeout', '来源读取超时。'),
        ),
      );
      final response = () async {
        check();
        final json = await api!.request(
          'GET',
          '/v1/practice-sessions/$sessionId/completion',
          accountId: accountId,
        );
        check();
        try {
          String id(dynamic value) {
            if (value is! String || !isPracticeUuid(value)) {
              throw const FormatException();
            }
            return value.toLowerCase();
          }

          if (id(json['account_id']) != accountId ||
              id(json['session_id']) != sessionId ||
              json['epoch'] is! int ||
              (json['epoch'] as int) < 1 ||
              (json['epoch'] as int) > 2147483647) {
            throw const FormatException();
          }
          final scope = ConversationScope(
            accountId: accountId,
            sessionId: sessionId,
            connectionId: id(json['origin_connection_id']),
            clientInstanceId: id(json['client_instance_id']),
            epoch: json['epoch'] as int,
          );
          return PracticeCompletionSummary.fromJson(json, scope: scope);
        } on FormatException {
          throw const ApiException('invalid_response', '来源响应异常。');
        }
      }();
      final result = await Future.any([
        response,
        cancelled.future,
        deadline.future,
      ]);
      check();
      return result;
    } finally {
      timer?.cancel();
      _cancel = null;
      _active = null;
      api?.close();
    }
  }

  void _clearReview() {
    _review?.dispose();
    _review = null;
  }

  void _abort() {
    if (_aborted) return;
    _aborted = true;
    _state = ReviewPageState.aborted;
    _confirmed = false;
    _completion = null;
    _cancel?.call();
    _active?.close();
    _clearReview();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _abort();
    super.dispose();
  }
}
