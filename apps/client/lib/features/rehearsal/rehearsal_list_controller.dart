import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/api_client.dart';
import '../../core/http_client_factory.dart';
import '../practice/practice_models.dart';
import 'rehearsal_list_models.dart';
import 'rehearsal_list_repository.dart';

enum RehearsalListState { idle, reading, ready, failed, unavailable, aborted }

final class RehearsalListController extends ChangeNotifier {
  RehearsalListController({
    required ApiClient accountApi,
    required this.accountId,
    required this.sourceSessionId,
    http.Client Function()? httpClientFactory,
    Duration Function()? elapsed,
  }) : _source = accountApi,
       _factory = httpClientFactory ?? createHttpClient,
       _elapsed = elapsed ?? _clock();
  final ApiClient _source;
  final String accountId, sourceSessionId;
  final http.Client Function() _factory;
  final Duration Function() _elapsed;
  static Duration Function() _clock() {
    final c = Stopwatch()..start();
    return () => c.elapsed;
  }

  RehearsalListState _state = RehearsalListState.idle;
  RehearsalListPage? _page;
  String? _error;
  final _anchors = <RelatedRehearsal?>[null];
  int _index = 0;
  bool _disposed = false, _aborted = false;
  Future<void>? _task;
  ApiClient? _active;
  void Function()? _cancel;
  bool _owns() {
    if (_disposed || _aborted) {
      return false;
    }
    if (_source.hasCurrentAccount(accountId)) {
      return true;
    }
    _error = 'account_changed';
    _abort();
    return false;
  }

  RehearsalListState get state {
    _owns();
    return _state;
  }

  RehearsalListPage? get page => _owns() ? _page : null;
  String? get errorCode {
    _owns();
    return _error;
  }

  bool get busy => _owns() && _task != null;
  int get pageNumber => _index + 1;
  bool get canNext => _owns() && !busy && _page?.nextBeforeId != null;
  bool get canPrevious => _owns() && !busy && _page != null && _index > 0;
  bool canOpen(String id) =>
      _owns() && !busy && (_page?.items.any((item) => item.id == id) ?? false);
  Future<void> refresh() => _run(reset: true);
  Future<void> next() =>
      _task ??
      (!canNext
          ? Future.value()
          : _run(index: _index + 1, before: _page!.items.last));
  Future<void> previous() =>
      _task ??
      (!canPrevious
          ? Future.value()
          : _run(index: _index - 1, before: _anchors[_index - 1]));
  void _clear() {
    _page = null;
    _index = 0;
    _anchors
      ..clear()
      ..add(null);
  }

  Future<void> _run({
    bool reset = false,
    int index = 0,
    RelatedRehearsal? before,
  }) {
    if (!_owns()) {
      return Future.value();
    }
    if (_task != null) {
      return _task!;
    }
    if (!isPracticeUuid(accountId) || !isPracticeUuid(sourceSessionId)) {
      _clear();
      _error = 'invalid_source';
      _state = RehearsalListState.unavailable;
      notifyListeners();
      return Future.value();
    }
    if (reset) {
      _clear();
    }
    final done = Completer<void>();
    _task = done.future;
    _error = null;
    _state = RehearsalListState.reading;
    notifyListeners();
    unawaited(
      Future<void>.microtask(() async {
        try {
          final result = await _read(before);
          if (!_owns()) {
            return;
          }
          _page = result;
          if (index >= _anchors.length) {
            _anchors.add(before);
          } else {
            _anchors[index] = before;
            _anchors.removeRange(index + 1, _anchors.length);
          }
          _index = index;
          _state = RehearsalListState.ready;
        } on Object catch (error) {
          if (!_owns()) {
            return;
          }
          final api = error is ApiException ? error : null;
          _error = api?.code ?? 'invalid_response';
          final transient =
              api?.statusCode != 401 &&
              api?.statusCode != 404 &&
              api?.statusCode != 409 &&
              {
                'network_error',
                'rehearsals_timeout',
                'service_unavailable',
                'rate_limited',
              }.contains(_error);
          if (!transient) {
            _clear();
          }
          if (api?.statusCode == 401 || _error == 'account_changed') {
            if (api?.statusCode == 401) {
              _error = 'unauthorized';
            }
            _abort();
          } else {
            _state = transient
                ? RehearsalListState.failed
                : RehearsalListState.unavailable;
          }
        } finally {
          _task = null;
          if (!_disposed) {
            notifyListeners();
          }
          done.complete();
        }
      }),
    );
    return done.future;
  }

  Future<RehearsalListPage> _read(RelatedRehearsal? before) async {
    final cutoff = _elapsed() + const Duration(seconds: 8);
    var live = true;
    void check() {
      if (!live || !_owns()) {
        throw const ApiException('cancelled', '读取已停止。');
      }
      if (_elapsed() >= cutoff) {
        throw const ApiException('rehearsals_timeout', '读取超时。');
      }
    }

    ApiClient? api;
    Timer? timer;
    try {
      check();
      api = _source.forkForAccount(accountId: accountId, client: _factory());
      _active = api;
      final stopped = Completer<RehearsalListPage>(),
          deadline = Completer<RehearsalListPage>();
      _cancel = () {
        if (!stopped.isCompleted) {
          stopped.completeError(const ApiException('cancelled', '读取已停止。'));
        }
      };
      timer = Timer(
        cutoff - _elapsed(),
        () => deadline.completeError(
          const ApiException('rehearsals_timeout', '读取超时。'),
        ),
      );
      final repository = RehearsalListRepository(
        api,
        accountId: accountId,
        sourceSessionId: sourceSessionId,
      );
      final work = () async {
        check();
        final result = await repository.read(before: before);
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
    if (_aborted) {
      return;
    }
    _aborted = true;
    _clear();
    _state = RehearsalListState.aborted;
    _cancel?.call();
    _active?.close();
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _abort();
    super.dispose();
  }
}
