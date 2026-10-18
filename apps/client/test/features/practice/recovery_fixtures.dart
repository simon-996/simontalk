import 'practice_fixtures.dart';

Map<String, dynamic> observationJson(int sequence, {String code = 'muted'}) => {
  'event_id': '66666666-6666-4666-8666-${sequence.toString().padLeft(12, '0')}',
  'sequence': sequence,
  'code': code,
  'elapsed_ms': sequence * 10,
  'reason': code == 'local_closed' ? 'user_stop' : null,
  'received_at': '2026-10-18T00:00:00Z',
};

Map<String, dynamic> pageJson({
  List<int> sequences = const [1, 3],
  int? total,
  int? last,
  int after = 0,
  bool more = false,
}) => {
  'source': 'client_observed',
  'connection_id': connectionId,
  'client_instance_id': clientId,
  'epoch': 1,
  'last_sequence': last ?? (sequences.isEmpty ? 0 : sequences.last),
  'total_events': total ?? sequences.length,
  'events': [for (final s in sequences) observationJson(s)],
  'next_after_sequence': sequences.isEmpty ? after : sequences.last,
  'has_more': more,
};
