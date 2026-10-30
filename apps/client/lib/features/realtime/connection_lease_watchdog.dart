import 'dart:async';

import '../practice/practice_models.dart';

/// Keeps the old monotonic cutoff armed while a renewal request is in flight.
class ConnectionLeaseWatchdog {
  ConnectionLeaseWatchdog({
    required this.elapsed,
    required this.onRenew,
    required this.onExpired,
  });
  final Duration Function() elapsed;
  final void Function() onRenew;
  final void Function() onExpired;
  Duration? _deadline;
  Timer? _renew;
  Timer? _expiry;

  bool get expired => _deadline != null && elapsed() >= _deadline!;
  Duration? get deadline => _deadline;

  void stopRenewal() => _renew?.cancel();

  bool arm(Duration requestStarted, ConnectionReservation connection) {
    final deadline = requestStarted + connection.leaseDuration;
    final remaining = deadline - elapsed();
    if (remaining <= Duration.zero) return false;
    stop();
    _deadline = deadline;
    _expiry = Timer(remaining, onExpired);
    _renew = Timer(const Duration(seconds: 15), onRenew);
    return true;
  }

  void stop() {
    _renew?.cancel();
    _expiry?.cancel();
    _deadline = null;
  }
}
