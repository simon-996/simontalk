import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/api_client.dart';
import '../../core/http_client_factory.dart';
import '../../core/random_uuid.dart';
import '../account/account_models.dart';
import '../practice/practice_models.dart';
import 'rehearsal_models.dart';
import 'rehearsal_repository.dart';

enum RehearsalState {
  idle,
  reading,
  ready,
  creating,
  unconfirmed,
  prepared,
  discarding,
  cancelled,
  failed,
  aborted,
}

/// One owner, verified target and immutable explicit creation request. No media.
final class RehearsalController extends ChangeNotifier {
  RehearsalController({
    required ApiClient accountApi,
    required this.accountId,
    required this.sessionId,
    this.itemId,
    http.Client Function()? httpClientFactory,
    String Function()? keyFactory,
    Duration Function()? elapsed,
  }) : _source = accountApi,
       _factory = httpClientFactory ?? createHttpClient,
       _newKey = keyFactory ?? randomUuid,
       _elapsed = elapsed ?? _clock();
  final ApiClient _source;
  final String accountId, sessionId;
  final String? itemId;
  final http.Client Function() _factory;
  final String Function() _newKey;
  final Duration Function() _elapsed;
  static Duration Function() _clock() {
    final c = Stopwatch()..start();
    return () => c.elapsed;
  }

  RehearsalState _state = RehearsalState.idle;
  RehearsalTarget? _target, _pending;
  PracticePreparation? _preparation;
  Difficulty? _difficulty, _pendingDifficulty;
  String? _key, _error;
  bool _disposed = false, _aborted = false, _discardBlocked = false;
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

  RehearsalState get state {
    _owns();
    return _state;
  }

  RehearsalTarget? get target => _owns() ? _target : null;
  PracticePreparation? get preparation => _owns() ? _preparation : null;
  Difficulty? get difficulty => _owns() ? _difficulty : null;
  String? get errorCode {
    _owns();
    return _error;
  }

  bool get busy => _owns() && _task != null;
  bool get canConfirm =>
      _owns() &&
      !busy &&
      itemId != null &&
      _state == RehearsalState.ready &&
      _target != null &&
      _difficulty != null;
  bool get canReplay =>
      _owns() &&
      !busy &&
      _state == RehearsalState.unconfirmed &&
      _pending != null;
  bool get canDiscard =>
      _owns() &&
      !busy &&
      !_discardBlocked &&
      _state == RehearsalState.prepared &&
      _preparation?.status == PracticeStatus.created &&
      _preparation?.connectionEpoch == 0;
  void selectDifficulty(Difficulty value) {
    if (!_owns() || busy || _pending != null || _preparation != null) return;
    _difficulty = value;
    notifyListeners();
  }

  Future<void> load() =>
      _task ??
      (_pending != null || _preparation != null
          ? Future.value()
          : _run('read'));
  Future<void> confirm() {
    if (_task != null) return _task!;
    if (!canConfirm) return Future.value();
    _pending = _target;
    _pendingDifficulty = _difficulty;
    _key = _newKey();
    return _run('create');
  }

  Future<void> replay() =>
      _task ?? (!canReplay ? Future.value() : _run('create'));
  Future<void> discard() =>
      _task ?? (!canDiscard ? Future.value() : _run('discard'));
  Future<void> _run(String op) {
    if (!_owns()) return Future.value();
    if (!isPracticeUuid(accountId) ||
        !isPracticeUuid(sessionId) ||
        itemId != null && !isPracticeUuid(itemId!) ||
        _key != null && !isPracticeUuid(_key!)) {
      _error = 'invalid_source';
      _state = RehearsalState.failed;
      notifyListeners();
      return Future.value();
    }
    final done = Completer<void>();
    _task = done.future;
    _error = null;
    if (op == 'read') _target = null;
    _state = op == 'read'
        ? RehearsalState.reading
        : op == 'create'
        ? RehearsalState.creating
        : RehearsalState.discarding;
    notifyListeners();
    unawaited(
      Future<void>.microtask(() async {
        try {
          if (op == 'read') {
            final result = await _bounded((repo, check) => repo.load(check));
            if (!_owns()) return;
            _target = result;
            _state = RehearsalState.ready;
          } else if (op == 'create') {
            final result = await _bounded(
              (repo, check) =>
                  repo.create(_pending!, _pendingDifficulty!, _key!),
            );
            if (!_owns()) return;
            _preparation = result;
            _pending = null;
            _key = null;
            _pendingDifficulty = null;
            _state = RehearsalState.prepared;
          } else {
            final result = await _bounded(
              (repo, check) => repo.discard(_preparation!),
            );
            if (!_owns()) return;
            _preparation = result;
            _state = RehearsalState.cancelled;
          }
        } on Object catch (error) {
          if (!_owns()) return;
          final api = error is ApiException ? error : null;
          _error = api?.code ?? 'invalid_response';
          if (api?.statusCode == 401 || _error == 'account_changed') {
            if (api?.statusCode == 401) _error = 'unauthorized';
            _abort();
          } else if (op == 'discard') {
            if (api?.statusCode == 404) {
              _target = null;
              _preparation = null;
              _state = RehearsalState.failed;
            } else {
              _discardBlocked = api?.statusCode == 409;
              _state = RehearsalState.prepared;
            }
          } else if (op == 'create' &&
              _error != 'realtime_unavailable' &&
              !(api?.statusCode != null &&
                  api!.statusCode! >= 400 &&
                  api.statusCode! < 500 &&
                  api.statusCode != 408)) {
            _state = RehearsalState.unconfirmed;
          } else {
            _pending = null;
            _key = null;
            _pendingDifficulty = null;
            _target = null;
            _state = RehearsalState.failed;
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

  Future<T> _bounded<T>(
    Future<T> Function(RehearsalRepository, void Function()) action,
  ) async {
    final cutoff = _elapsed() + const Duration(seconds: 8);
    var live = true;
    void check() {
      if (!live || !_owns()) throw const ApiException('cancelled', '操作已停止。');
      if (_elapsed() >= cutoff) {
        throw const ApiException('rehearsal_timeout', '重练请求超时。');
      }
    }

    ApiClient? api;
    Timer? timer;
    try {
      check();
      api = _source.forkForAccount(accountId: accountId, client: _factory());
      _active = api;
      final stopped = Completer<T>(), deadline = Completer<T>();
      _cancel = () {
        if (!stopped.isCompleted) {
          stopped.completeError(const ApiException('cancelled', '操作已停止。'));
        }
      };
      timer = Timer(
        cutoff - _elapsed(),
        () => deadline.completeError(
          const ApiException('rehearsal_timeout', '重练请求超时。'),
        ),
      );
      final repo = RehearsalRepository(
        api,
        accountId: accountId,
        sessionId: sessionId,
        itemId: itemId,
      );
      final work = () async {
        check();
        final result = await action(repo, check);
        check();
        return result;
      }();
      final result = await Future.any([work, stopped.future, deadline.future]);
      check();
      return result;
    } finally {
      live = false;
      timer?.cancel();
      _cancel = null;
      _active = null;
      api?.close();
    }
  }

  void _abort() {
    if (_aborted) return;
    _aborted = true;
    _target = null;
    _pending = null;
    _preparation = null;
    _key = null;
    _difficulty = null;
    _pendingDifficulty = null;
    _state = RehearsalState.aborted;
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
