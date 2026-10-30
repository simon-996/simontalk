import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/api_client.dart';
import '../../core/http_client_factory.dart';
import '../practice/practice_models.dart';
import 'history_models.dart';
import 'history_repository.dart';

enum HistoryState { idle, reading, ready, failed, unavailable, aborted }

typedef _Content = ({HistoryPage? page, HistoryItem? item});

/// Holds one page and seek positions, with one bounded owner-bound GET per action.
final class HistoryController extends ChangeNotifier {
  HistoryController({
    required ApiClient accountApi,
    required this.accountId,
    this.sessionId,
    http.Client Function()? httpClientFactory,
    Duration Function()? elapsed,
  }) : _source = accountApi,
       _factory = httpClientFactory ?? createHttpClient,
       _elapsed = elapsed ?? _clock();
  final ApiClient _source;
  final String accountId;
  final String? sessionId;
  final http.Client Function() _factory;
  final Duration Function() _elapsed;
  static Duration Function() _clock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsed;
  }

  bool _disposed = false, _aborted = false;
  HistoryPage? _page;
  HistoryItem? _item;
  HistoryState _state = HistoryState.idle;
  String? _error;
  final _cursors = <String?>[null];
  int _index = 0;
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

  HistoryState get state {
    _owns();
    return _state;
  }

  HistoryPage? get page => _owns() ? _page : null;
  HistoryItem? get item => _owns() ? _item : null;
  String? get errorCode {
    _owns();
    return _error;
  }

  bool get busy => _owns() && _task != null;
  int get pageNumber => _index + 1;
  bool get canPrevious => _owns() && !busy && _page != null && _index > 0;
  bool get canNext => _owns() && !busy && _page?.nextCursor != null;
  Future<void> refresh() => _run(reset: true);
  Future<void> next() =>
      _task ??
      (!canNext
          ? Future.value()
          : _run(target: _index + 1, cursor: _page!.nextCursor));
  Future<void> previous() =>
      _task ??
      (!canPrevious
          ? Future.value()
          : _run(target: _index - 1, cursor: _cursors[_index - 1]));
  Future<void> _run({bool reset = false, int target = 0, String? cursor}) {
    if (!_owns()) return Future.value();
    if (_task != null) return _task!;
    if (!isPracticeUuid(accountId) ||
        sessionId != null && !isPracticeUuid(sessionId!)) {
      _error = 'invalid_source';
      _state = HistoryState.unavailable;
      notifyListeners();
      return Future.value();
    }
    if (reset) {
      _page = null;
      _item = null;
      _cursors
        ..clear()
        ..add(null);
      _index = 0;
    }
    _error = null;
    _state = HistoryState.reading;
    final done = Completer<void>();
    _task = done.future;
    notifyListeners();
    unawaited(
      Future<void>.microtask(() async {
        try {
          final content = await _read(cursor);
          if (!_owns()) return;
          _page = content.page;
          _item = content.item;
          if (target >= _cursors.length) {
            _cursors.add(cursor);
          } else {
            _cursors[target] = cursor;
            _cursors.removeRange(target + 1, _cursors.length);
          }
          _index = target;
          _state = HistoryState.ready;
        } on Object catch (error) {
          if (!_owns()) return;
          final api = error is ApiException ? error : null;
          _error = api?.code ?? 'invalid_response';
          final transient =
              api?.statusCode != 401 &&
              api?.statusCode != 404 &&
              api?.statusCode != 409 &&
              {
                'network_error',
                'history_timeout',
                'service_unavailable',
                'rate_limited',
              }.contains(_error);
          if (!transient) {
            _page = null;
            _item = null;
          }
          if (api?.statusCode == 401 || _error == 'account_changed') {
            _error = api?.statusCode == 401
                ? 'unauthorized'
                : 'account_changed';
            _abort();
          } else {
            _state = transient ? HistoryState.failed : HistoryState.unavailable;
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

  Future<_Content> _read(String? cursor) async {
    final cutoff = _elapsed() + const Duration(seconds: 8);
    void check() {
      if (!_owns()) throw const ApiException('cancelled', '读取已停止。');
      if (_elapsed() >= cutoff) {
        throw const ApiException('history_timeout', '记录读取超时。');
      }
    }

    ApiClient? api;
    Timer? timer;
    try {
      check();
      api = _source.forkForAccount(accountId: accountId, client: _factory());
      _active = api;
      final cancelled = Completer<_Content>();
      _cancel = () {
        if (!cancelled.isCompleted) {
          cancelled.completeError(const ApiException('cancelled', '读取已停止。'));
        }
      };
      final deadline = Completer<_Content>();
      timer = Timer(
        cutoff - _elapsed(),
        () => deadline.completeError(
          const ApiException('history_timeout', '记录读取超时。'),
        ),
      );
      final repository = HistoryRepository(api, accountId: accountId);
      final response = () async {
        check();
        final _Content content = sessionId == null
            ? (page: await repository.readPage(cursor: cursor), item: null)
            : (page: null, item: await repository.readDetail(sessionId!));
        check();
        return content;
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
    _page = null;
    _item = null;
    _state = HistoryState.aborted;
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
