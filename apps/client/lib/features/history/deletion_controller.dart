import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/api_client.dart';
import '../../core/http_client_factory.dart';
import '../../core/random_uuid.dart';
import '../practice/practice_models.dart';
import 'deletion_models.dart';

enum DeletionState {
  idle,
  reading,
  ready,
  deleting,
  unconfirmed,
  deleted,
  failed,
  aborted,
}

/// One confirmed scope and one immutable request survive an uncertain response.
final class DeletionController extends ChangeNotifier {
  DeletionController({
    required ApiClient accountApi,
    required this.accountId,
    required this.sessionId,
    http.Client Function()? httpClientFactory,
    String Function()? keyFactory,
    Duration Function()? elapsed,
  }) : _source = accountApi,
       _factory = httpClientFactory ?? createHttpClient,
       _newKey = keyFactory ?? randomUuid,
       _elapsed = elapsed ?? _clock();
  final ApiClient _source;
  final String accountId, sessionId;
  final http.Client Function() _factory;
  final String Function() _newKey;
  final Duration Function() _elapsed;
  static Duration Function() _clock() {
    final c = Stopwatch()..start();
    return () => c.elapsed;
  }

  DeletionState _state = DeletionState.idle;
  DeletionScope? _scope, _pending;
  DeletionReceipt? _receipt;
  String? _key, _error;
  bool _disposed = false, _aborted = false, _canReplay = false;
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

  DeletionState get state {
    _owns();
    return _state;
  }

  DeletionScope? get scope => _owns() ? _scope : null;
  DeletionReceipt? get receipt => _owns() ? _receipt : null;
  String? get errorCode {
    _owns();
    return _error;
  }

  bool get busy => _owns() && _task != null;
  bool get canReplay => _owns() && _canReplay && !busy;
  Future<void> load() =>
      _task ??
      (_pending != null || _state == DeletionState.deleted
          ? Future.value()
          : _run('scope'));
  Future<void> confirm() {
    if (_task != null) return _task!;
    if (!_owns() || _state != DeletionState.ready || _scope == null) {
      return Future.value();
    }
    _pending = _scope;
    _key = _newKey();
    return _run('delete');
  }

  Future<void> check() =>
      _task ?? (_pending == null ? Future.value() : _run('check'));
  Future<void> replay() =>
      _task ?? (!canReplay ? Future.value() : _run('delete'));
  String get _path => '/v1/practice-history/$sessionId';
  Future<void> _run(String operation) {
    if (!_owns()) return Future.value();
    if (!isPracticeUuid(accountId) ||
        !isPracticeUuid(sessionId) ||
        _key != null && !isPracticeUuid(_key!)) {
      _error = 'invalid_source';
      _scope = null;
      _state = DeletionState.failed;
      notifyListeners();
      return Future.value();
    }
    final done = Completer<void>();
    _task = done.future;
    _error = null;
    _canReplay = false;
    if (operation == 'scope') _scope = null;
    _state = operation == 'delete'
        ? DeletionState.deleting
        : DeletionState.reading;
    notifyListeners();
    unawaited(
      Future<void>.microtask(() async {
        try {
          final j = await _request(operation);
          if (!_owns()) return;
          if (operation == 'scope') {
            _scope = DeletionScope.fromJson(
              j,
              accountId: accountId,
              sessionId: sessionId,
            );
            _state = DeletionState.ready;
          } else {
            _receipt = DeletionReceipt.fromJson(
              j,
              scope: _pending!,
              requestKey: _key!,
            );
            _scope = null;
            _pending = null;
            _key = null;
            _state = DeletionState.deleted;
          }
        } on Object catch (error) {
          if (!_owns()) return;
          final api = error is ApiException ? error : null;
          _error = api?.code ?? 'invalid_response';
          if (api?.statusCode == 401 || _error == 'account_changed') {
            if (api?.statusCode == 401) _error = 'unauthorized';
            _abort();
          } else if (operation == 'scope') {
            _scope = null;
            _state = DeletionState.failed;
          } else if (operation == 'check') {
            _state = DeletionState.unconfirmed;
            _canReplay =
                api?.statusCode == 404 &&
                _error == 'deletion_receipt_not_found';
          } else if (api?.statusCode != null &&
              api!.statusCode! >= 400 &&
              api.statusCode! < 500 &&
              api.statusCode != 408) {
            // A definite refusal needs a freshly read scope and new confirmation.
            _pending = null;
            _key = null;
            _scope = null;
            _state = DeletionState.failed;
          } else {
            _state = DeletionState.unconfirmed;
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

  Future<Map<String, dynamic>> _request(String operation) async {
    final cutoff = _elapsed() + const Duration(seconds: 8);
    void check() {
      if (!_owns()) throw const ApiException('cancelled', '操作已停止。');
      if (_elapsed() >= cutoff) {
        throw const ApiException('deletion_timeout', '操作超时。');
      }
    }

    ApiClient? api;
    Timer? timer;
    try {
      check();
      api = _source.forkForAccount(accountId: accountId, client: _factory());
      _active = api;
      final stopped = Completer<Map<String, dynamic>>(),
          deadline = Completer<Map<String, dynamic>>();
      _cancel = () {
        if (!stopped.isCompleted) {
          stopped.completeError(const ApiException('cancelled', '操作已停止。'));
        }
      };
      timer = Timer(
        cutoff - _elapsed(),
        () => deadline.completeError(
          const ApiException('deletion_timeout', '操作超时。'),
        ),
      );
      final response = () async {
        check();
        final j = await api!.request(
          operation == 'delete' ? 'DELETE' : 'GET',
          operation == 'scope'
              ? '$_path/deletion-scope'
              : operation == 'check'
              ? '$_path/deletion?key=$_key'
              : _path,
          accountId: accountId,
          idempotencyKey: operation == 'delete' ? _key : null,
          body: operation == 'delete'
              ? {'scope_version': _pending!.version}
              : null,
          maxResponseBytes: 8192,
        );
        check();
        return j;
      }();
      final result = await Future.any([
        response,
        stopped.future,
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
    _scope = null;
    _pending = null;
    _key = null;
    _receipt = null;
    _canReplay = false;
    _state = DeletionState.aborted;
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
