import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/features/conversation/conversation_models.dart';
import 'package:simontalk_client/features/practice/practice_completion_models.dart';
import 'package:simontalk_client/features/review/review_models.dart';

import '../practice/practice_completion_test.dart' show completionSummary;
import '../practice/practice_fixtures.dart';

void main() {
  test('ending input cannot authorize review', () {
    final scope = ConversationScope(
      accountId: accountId,
      sessionId: practiceId,
      connectionId: connectionId,
      clientInstanceId: clientId,
      epoch: 1,
    );
    final ending = PracticeCompletionSummary.fromJson(
      completionSummary(),
      scope: scope,
      endKey: requestKey,
    );
    expect(() => ReviewTarget.fromCompletion(ending), throwsFormatException);
  });
}
