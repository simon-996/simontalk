import 'review_fixtures.dart';

Map<String, dynamic> evaluationEvidenceJson() => {
  'source_connection_id': connectionId,
  'source_turn_id': turnId,
  'revision': 1,
  'exact_quote': 'Yesterday I went to the park.',
};

Map<String, dynamic> evaluationJson({
  String intent = 'conveyed',
  String targetIssue = 'demonstrated',
}) => {
  'schema_version': 'rehearsal_evaluation_v1',
  'target_hash': 'd' * 64,
  'intent': {
    'status': intent,
    'explanation': '本次仍在讲述昨天去公园的经历。',
    'evidence': intent == 'insufficient_evidence'
        ? []
        : [evaluationEvidenceJson()],
  },
  'target_issue': {
    'status': targetIssue,
    'explanation': '本次使用了过去式 went。',
    'evidence': targetIssue == 'insufficient_evidence'
        ? []
        : [evaluationEvidenceJson()],
  },
};

Map<String, dynamic> evaluatedJobJson({
  String intent = 'conveyed',
  String targetIssue = 'demonstrated',
  bool withSuggestion = false,
}) => {
  ...jobJson(status: 'succeeded'),
  'result': {
    ...resultJson(empty: !withSuggestion),
    'rehearsal_evaluation': evaluationJson(
      intent: intent,
      targetIssue: targetIssue,
    ),
  },
};
