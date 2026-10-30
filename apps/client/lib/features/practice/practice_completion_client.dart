import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/api_client.dart';
import '../../core/http_client_factory.dart';
import '../../core/random_uuid.dart';
import '../conversation/conversation_models.dart';
import 'practice_completion_models.dart';
import 'practice_models.dart';
import 'practice_repository.dart';

enum PracticeCompletionClientState {
  idle,
  working,
  waiting,
  failed,
  sealed,
  aborted,
}

abstract interface class RealtimePracticeCompletion extends Listenable {
  void requestEnd();
  void finish(PracticeCompletionManifest manifest);
  Future<void> retryPending();
  Future<void> refresh();
  void abort();
  bool get hasPendingWork;
  String? get errorCode;
  PracticeCompletionClientState get state;
  PracticeCompletionSummary? get summary;
  PracticeCompletionReceipt? get receipt;
}

typedef PracticeCompletionFactory = RealtimePracticeCompletion Function(
  ConversationScope scope,
);
typedef PracticeCompletionCreator = RealtimePracticeCompletion Function(
  ApiClient accountApi,
  ConversationScope scope,
);

/// Owns completion HTTP only; it never controls capture, a lease or termination.
class PracticeCompletionClient extends ChangeNotifier
    implements RealtimePracticeCompletion {
  PracticeCompletionClient({
    required ApiClient accountApi,
    required this.scope,
    http.Client Function()? clientFactory,
    Duration Function()? elapsed,
    String? endKey,
  }) : _source = accountApi,
       _clientFactory = clientFactory ?? createHttpClient,
       _elapsed = elapsed ?? _clock(),
       endKey = endKey ?? randomUuid() {
    if (!isPracticeUuid(this.endKey)) throw const FormatException();
  }
  final ApiClient _source;
  final ConversationScope scope;
  final String endKey;
  final http.Client Function() _clientFactory;
  final Duration Function() _elapsed;
  bool _requested = false;
  bool _endAccepted = false;
  bool _manifestAccepted = false;
  bool _manifestClosed = false;
  bool _aborted = false;
  bool _paused = false;
  PracticeCompletionManifest? _manifest;
  String? _manifestBody;
  PracticeCompletionSummary? _summary;
  PracticeCompletionReceipt? _receipt;
  PracticeCompletionClientState _state = PracticeCompletionClientState.idle;
  String? _error;
  Future<void>? _task;
  ApiClient? _activeApi;
  void Function()? _cancel;
  Timer? _pollTimer;
  int _pollAttempts = 0;
  Duration? _pollDeadline;
  static Duration Function() _clock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsed;
  }

  bool _ownsAccount() {
    if (_aborted) return false;
    if (_source.hasCurrentAccount(scope.accountId)) return true;
    _error = 'account_changed';
    abort();
    return false;
  }

  @override
  bool get hasPendingWork => _ownsAccount() && _requested && _receipt == null;
  @override
  String? get errorCode {
    _ownsAccount();
    return _error;
  }

  @override
  PracticeCompletionClientState get state {
    _ownsAccount();
    return _state;
  }

  @override
  PracticeCompletionSummary? get summary => _ownsAccount() ? _summary : null;
  @override
  PracticeCompletionReceipt? get receipt => _ownsAccount() ? _receipt : null;

  @override
  void requestEnd() {
    if (!_ownsAccount() || _requested) return;
    _requested = true;
    _state = PracticeCompletionClientState.working;
    _schedule();
    notifyListeners();
  }

  @override
  void finish(PracticeCompletionManifest manifest) {
    if (!_ownsAccount()) return;
    if (!sameCompletionScope(scope, manifest.scope)) {
      throw const ApiException('invalid_request', '结束清单范围无效。');
    }
    final body = jsonEncode(manifest.toRequestJson());
    if (_manifestBody != null && body != _manifestBody) {
      throw const ApiException('completion_manifest_conflict', '结束清单已固定。');
    }
    final firstManifest = _manifestBody == null;
    _manifest ??= manifest;
    _manifestBody ??= body;
    if (_requested && firstManifest) {
      final current = _task;
      if (current == null) {
        _schedule();
      } else {
        // Queue this first capture without turning a later read-only refresh
        // into an implicit retry of a previously failed write.
        unawaited(
          current.then((_) {
            if (!_paused && !_manifestAccepted && !_manifestClosed) _schedule();
          }),
        );
      }
    }
  }

  void _schedule() {
    if (_aborted ||
        _paused ||
        !_requested ||
        _receipt != null ||
        _task != null) {
      return;
    }
    _pollTimer?.cancel();
    _task = Future<void>.microtask(_drive);
  }

  @override
  Future<void> retryPending() {
    if (!_ownsAccount() || !_requested || _receipt != null) {
      return Future.value();
    }
    if (_task != null) return _task!;
    _paused = false;
    _error = null;
    _pollAttempts = 0;
    _pollDeadline = null;
    _schedule();
    notifyListeners();
    return _task ?? Future.value();
  }

  @override
  Future<void> refresh() {
    if (!_ownsAccount() || !_endAccepted || _receipt != null) {
      return Future.value();
    }
    if (_task != null) return _task!;
    _paused = false;
    _error = null;
    _pollTimer?.cancel();
    _task = Future<void>.microtask(() => _drive(readOnly: true));
    return _task!;
  }

  Future<void> _drive({bool readOnly = false}) async {
    if (!_ownsAccount()) {
      _task = null;
      return;
    }
    _state = PracticeCompletionClientState.working;
    notifyListeners();
    try {
      if (!_endAccepted && !readOnly) {
        final next = await _exchange(
          (repo) => repo.endPracticeConnection(scope, key: endKey),
        );
        if (!_ownsAccount()) return;
        _acceptSummary(next);
        _endAccepted = true;
      } else if (_summary?.status != PracticeCompletionStatus.sealed &&
          (readOnly || _manifestAccepted || _manifestClosed)) {
        final next = await _exchange(
          (repo) => repo.loadPracticeCompletion(scope, endKey: endKey),
        );
        if (!_ownsAccount()) return;
        _acceptSummary(next);
      }
      if (_summary?.status != PracticeCompletionStatus.sealed &&
          !readOnly &&
          _manifest != null &&
          !_manifestAccepted &&
          !_manifestClosed) {
        try {
          final next = await _exchange(
            (repo) => repo.submitPracticeCompletionManifest(
              _manifest!,
              endKey: endKey,
            ),
          );
          if (!_ownsAccount()) return;
          _acceptSummary(next);
          _manifestAccepted = true;
        } on ApiException catch (error) {
          if (error.code != 'practice_input_sealed') rethrow;
          _manifestClosed = true;
          final next = await _exchange(
            (repo) => repo.loadPracticeCompletion(scope, endKey: endKey),
          );
          if (!_ownsAccount()) return;
          _acceptSummary(next);
        }
      }
      if (_summary?.status == PracticeCompletionStatus.sealed) {
        final receipt = await _exchange(
          (repo) => repo.loadPracticeCompletionReceipt(
            scope,
            practiceInputHash: _summary!.inputHash!,
          ),
        );
        if (!_ownsAccount()) return;
        _receipt = receipt;
        _state = PracticeCompletionClientState.sealed;
        _pollTimer?.cancel();
      } else {
        _state = PracticeCompletionClientState.waiting;
      }
      _error = null;
    } on Object catch (error) {
      if (_aborted) return;
      if (!_source.hasCurrentAccount(scope.accountId) ||
          (error is ApiException && error.code == 'account_changed')) {
        _error = 'account_changed';
        abort();
      } else if (error is ApiException && error.code == 'unauthorized') {
        _error = 'unauthorized';
        abort();
      } else {
        _paused = true;
        _state = PracticeCompletionClientState.failed;
        _error = _safeError(error);
      }
    } finally {
      _task = null;
      if (!_aborted) {
        _schedulePoll();
        notifyListeners();
      }
    }
  }

  void _acceptSummary(PracticeCompletionSummary next) {
    final old = _summary;
    if (old != null &&
        (!old.sameFixedIdentity(next) ||
            (old.status == PracticeCompletionStatus.sealed &&
                !old.sameSealedInput(next)))) {
      throw const ApiException('invalid_response', '结束状态响应异常。');
    }
    _summary = next;
  }

  void _schedulePoll() {
    if (_aborted ||
        _paused ||
        _receipt != null ||
        (!_manifestAccepted && !_manifestClosed)) {
      return;
    }
    _pollDeadline ??= _elapsed() + const Duration(seconds: 40);
    if (_pollAttempts >= 20 || _elapsed() >= _pollDeadline!) {
      _paused = true;
      _state = PracticeCompletionClientState.failed;
      _error = 'completion_pending';
      return;
    }
    _pollTimer = Timer(const Duration(seconds: 2), () {
      if (_elapsed() >= _pollDeadline!) {
        _paused = true;
        _state = PracticeCompletionClientState.failed;
        _error = 'completion_pending';
        notifyListeners();
        return;
      }
      _pollAttempts++;
      unawaited(refresh());
    });
  }

  Future<T> _exchange<T>(
    Future<T> Function(PracticeRepository) operation,
  ) async {
    final cutoff = _elapsed() + const Duration(seconds: 8);
    final api = _activeApi = _source.forkForAccount(
      accountId: scope.accountId,
      client: _clientFactory(),
    );
    final cancelled = Completer<T>();
    final deadline = Completer<T>();
    _cancel = () {
      if (!cancelled.isCompleted) {
        cancelled.completeError(const ApiException('cancelled', '结束保存已停止。'));
      }
    };
    final remaining = cutoff - _elapsed();
    if (_aborted || remaining <= Duration.zero) {
      _activeApi = null;
      _cancel = null;
      api.close();
      throw ApiException(
        _aborted ? 'cancelled' : 'completion_timeout',
        '结束保存已停止。',
      );
    }
    final timer = Timer(
      remaining,
      () => deadline.completeError(
        const ApiException('completion_timeout', '结束保存超时。'),
      ),
    );
    try {
      final result = await Future.any([
        operation(PracticeRepository(api, accountId: scope.accountId)),
        cancelled.future,
        deadline.future,
      ]);
      if (_elapsed() >= cutoff) {
        throw const ApiException('completion_timeout', '结束保存超时。');
      }
      return result;
    } finally {
      timer.cancel();
      _cancel = null;
      _activeApi = null;
      api.close();
    }
  }

  static String _safeError(Object error) {
    const codes = {
      'network_error',
      'completion_timeout',
      'invalid_response',
      'csrf_invalid',
      'origin_forbidden',
      'completion_manifest_conflict',
      'completion_conflict',
      'completion_not_found',
      'completion_not_sealed',
      'practice_input_sealed',
      'practice_not_found',
      'connection_not_found',
      'connection_state_changed',
    };
    return error is ApiException && codes.contains(error.code)
        ? error.code
        : 'completion_failed';
  }

  @override
  void abort() {
    if (_aborted) return;
    _aborted = true;
    _state = PracticeCompletionClientState.aborted;
    _pollTimer?.cancel();
    _cancel?.call();
    _activeApi?.close();
    _manifest = null;
    _manifestBody = null;
    _summary = null;
    _receipt = null;
    notifyListeners();
  }
}
