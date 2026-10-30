import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/api_client.dart';
import '../../core/http_client_factory.dart';
import '../history/history_models.dart';
import '../history/history_repository.dart';
import '../transcript/saved_transcript_repository.dart';
import 'practice_completion_models.dart';
import 'practice_models.dart';

enum SavedPracticeStatusState {
  idle,
  reading,
  ready,
  failed,
  unavailable,
  aborted,
}

/// A read-only, owner-bound view of one practice, independent of current media.
final class SavedPracticeStatusController extends ChangeNotifier {
  SavedPracticeStatusController({
    required ApiClient accountApi,
    required this.accountId,
    required this.sessionId,
    http.Client Function()? httpClientFactory,
    Duration Function()? elapsed,
  }) : _source = accountApi,
       _factory = httpClientFactory ?? createHttpClient,
       _elapsed = elapsed ?? _clock();
  final ApiClient _source;
  final String accountId, sessionId;
  final http.Client Function() _factory;
  final Duration Function() _elapsed;
  static Duration Function() _clock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsed;
  }

  SavedPracticeStatusState _state = SavedPracticeStatusState.idle;
  HistoryItem? _item;
  PracticeCompletionSummary? _completion;
  String? _error;
  bool _disposed = false, _aborted = false;
  Future<void>? _task;
  ApiClient? _active;
  void Function()? _cancel;
  bool _owns() {
    if (_disposed || _aborted) return false;
    if (_source.hasCurrentAccount(accountId)) return true;
    _error = 'account_changed';
    _abort();
    return false;
  }

  SavedPracticeStatusState get state {
    _owns();
    return _state;
  }

  bool get busy => _owns() && _task != null;
  HistoryItem? get item => _owns() ? _item : null;
  PracticeCompletionSummary? get completion => _owns() ? _completion : null;
  String? get errorCode {
    _owns();
    return _error;
  }

  Future<void> refresh() {
    if (!_owns()) return Future.value();
    if (_task != null) return _task!;
    _item = null;
    _completion = null;
    _error = null;
    if (!isPracticeUuid(accountId) || !isPracticeUuid(sessionId)) {
      _state = SavedPracticeStatusState.unavailable;
      _error = 'invalid_source';
      notifyListeners();
      return Future.value();
    }
    final done = Completer<void>();
    _task = done.future;
    _state = SavedPracticeStatusState.reading;
    notifyListeners();
    unawaited(
      Future<void>.microtask(() async {
        try {
          final (item, completion) = await _read();
          if (!_owns()) return;
          _item = item;
          _completion = completion;
          _state = SavedPracticeStatusState.ready;
        } on Object catch (error) {
          if (!_owns()) return;
          final api = error is ApiException ? error : null;
          _error = api?.code ?? 'invalid_response';
          if (api?.statusCode == 401 || _error == 'account_changed') {
            if (api?.statusCode == 401) _error = 'unauthorized';
            _abort();
          } else {
            _state = api?.statusCode == 404
                ? SavedPracticeStatusState.unavailable
                : SavedPracticeStatusState.failed;
          }
        } finally {
          _task = null;
          if (!_disposed) notifyListeners();
          done.complete();
        }
      }),
    );
    return done.future;
  }

  Future<(HistoryItem, PracticeCompletionSummary?)> _read() async {
    final cutoff = _elapsed() + const Duration(seconds: 8);
    void check() {
      if (!_owns()) throw const ApiException('cancelled', '读取已停止。');
      if (_elapsed() >= cutoff) {
        throw const ApiException('save_status_timeout', '保存状态读取超时。');
      }
    }

    ApiClient? api;
    Timer? timer;
    try {
      check();
      api = _source.forkForAccount(accountId: accountId, client: _factory());
      _active = api;
      final cancelled = Completer<(HistoryItem, PracticeCompletionSummary?)>();
      final deadline = Completer<(HistoryItem, PracticeCompletionSummary?)>();
      _cancel = () {
        if (!cancelled.isCompleted) {
          cancelled.completeError(const ApiException('cancelled', '读取已停止。'));
        }
      };
      timer = Timer(
        cutoff - _elapsed(),
        () => deadline.completeError(
          const ApiException('save_status_timeout', '保存状态读取超时。'),
        ),
      );
      final response = () async {
        check();
        final item = await HistoryRepository(
          api!,
          accountId: accountId,
        ).readDetail(sessionId);
        check();
        PracticeCompletionSummary? completion;
        try {
          completion = await SavedTranscriptRepository(
            api!,
            accountId: accountId,
            sessionId: sessionId,
          ).readCompletion();
        } on ApiException catch (error) {
          check();
          if (error.statusCode != 404 || error.code != 'completion_not_found') {
            rethrow;
          }
          if (item.completionStatus != 'unregistered') {
            throw const ApiException('save_status_changed', '保存状态已变化，请重新读取。');
          }
        }
        check();
        if (completion != null &&
            (completion.status.name != item.completionStatus ||
                completion.coverage.name != item.coverage)) {
          throw const ApiException('save_status_changed', '保存状态已变化，请重新读取。');
        }
        return (item, completion);
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

  void _abort() {
    if (_aborted) return;
    _aborted = true;
    _state = SavedPracticeStatusState.aborted;
    _item = null;
    _completion = null;
    _cancel?.call();
    _active?.close();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _abort();
    super.dispose();
  }
}
