import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/api_client.dart';
import '../../core/http_client_factory.dart';
import '../practice/practice_models.dart';
import 'usage_models.dart';
import 'usage_repository.dart';

enum UsageReadState { idle, reading, ready, failed, unavailable, aborted }

abstract base class OwnerUsageController<T> extends ChangeNotifier {
  OwnerUsageController({
    required ApiClient accountApi,
    required this.accountId,
    http.Client Function()? httpClientFactory,
    Duration Function()? elapsed,
  }) : _source = accountApi,
       _factory = httpClientFactory ?? createHttpClient,
       _elapsed = elapsed ?? _clock();

  final ApiClient _source;
  final String accountId;
  final http.Client Function() _factory;
  final Duration Function() _elapsed;

  static Duration Function() _clock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsed;
  }

  UsageReadState _state = UsageReadState.idle;
  T? _summary;
  String? _error;
  bool _disposed = false;
  bool _aborted = false;
  Future<void>? _task;
  ApiClient? _active;
  void Function()? _cancel;

  bool get _validIds;
  Future<T> _fetch(UsageRepository repository);

  bool _owns() {
    if (_disposed || _aborted) return false;
    if (_source.hasCurrentAccount(accountId)) return true;
    _error = 'account_changed';
    _abort();
    return false;
  }

  UsageReadState get state {
    _owns();
    return _state;
  }

  bool get busy => _owns() && _task != null;
  T? get summary => _owns() ? _summary : null;
  String? get errorCode {
    _owns();
    return _error;
  }

  Future<void> refresh() {
    if (!_owns()) return Future.value();
    if (_task != null) return _task!;
    _summary = null;
    _error = null;
    if (!_validIds) {
      _state = UsageReadState.unavailable;
      _error = 'invalid_source';
      notifyListeners();
      return Future.value();
    }
    final done = Completer<void>();
    _task = done.future;
    _state = UsageReadState.reading;
    notifyListeners();
    unawaited(
      Future<void>.microtask(() async {
        try {
          final loaded = await _readBounded();
          if (!_owns()) return;
          _summary = loaded;
          _state = UsageReadState.ready;
        } on Object catch (error) {
          if (!_owns()) return;
          final api = error is ApiException ? error : null;
          _error = api?.code ?? 'invalid_response';
          if (api?.statusCode == 401 || _error == 'account_changed') {
            if (api?.statusCode == 401) _error = 'unauthorized';
            _abort();
          } else {
            _state = api?.statusCode == 404
                ? UsageReadState.unavailable
                : UsageReadState.failed;
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

  Future<T> _readBounded() async {
    final cutoff = _elapsed() + const Duration(seconds: 8);
    void check() {
      if (!_owns()) throw const ApiException('cancelled', '读取已停止。');
      if (_elapsed() >= cutoff) {
        throw const ApiException('usage_timeout', '用量读取超时。');
      }
    }

    ApiClient? api;
    Timer? timer;
    try {
      check();
      api = _source.forkForAccount(accountId: accountId, client: _factory());
      _active = api;
      final cancelled = Completer<T>();
      final deadline = Completer<T>();
      _cancel = () {
        if (!cancelled.isCompleted) {
          cancelled.completeError(const ApiException('cancelled', '读取已停止。'));
        }
      };
      timer = Timer(
        cutoff - _elapsed(),
        () => deadline.completeError(
          const ApiException('usage_timeout', '用量读取超时。'),
        ),
      );
      final response = () async {
        check();
        final loaded = await _fetch(
          UsageRepository(api!, accountId: accountId),
        );
        check();
        return loaded;
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
    _state = UsageReadState.aborted;
    _summary = null;
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

final class AccountUsageController
    extends OwnerUsageController<AccountUsageSummary> {
  AccountUsageController({
    required super.accountApi,
    required super.accountId,
    super.httpClientFactory,
    super.elapsed,
  });

  @override
  bool get _validIds => isPracticeUuid(accountId);

  @override
  Future<AccountUsageSummary> _fetch(UsageRepository repository) =>
      repository.readAccountUsage();
}

final class PracticeUsageController
    extends OwnerUsageController<PracticeUsageSummary> {
  PracticeUsageController({
    required super.accountApi,
    required super.accountId,
    required this.sessionId,
    super.httpClientFactory,
    super.elapsed,
  });

  final String sessionId;

  @override
  bool get _validIds => isPracticeUuid(accountId) && isPracticeUuid(sessionId);

  @override
  Future<PracticeUsageSummary> _fetch(UsageRepository repository) =>
      repository.readPracticeUsage(sessionId);
}
