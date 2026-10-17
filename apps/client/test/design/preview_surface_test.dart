import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simontalk_client/design/preview_surface.dart';

void main() {
  testWidgets('preview does not build text until local fonts have loaded', (
    tester,
  ) async {
    final fonts = Completer<void>();
    var builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PreviewFontGate(
          fonts: fonts.future,
          child: Builder(
            builder: (_) {
              builds++;
              return const Text('本地字体已就绪');
            },
          ),
        ),
      ),
    );
    expect(builds, 0);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    fonts.complete();
    await tester.pump();
    expect(builds, 1);
    expect(find.text('本地字体已就绪'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets(
    'font failure is visible and never renders an unprepared preview',
    (tester) async {
      final fonts = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: PreviewFontGate(
            fonts: fonts.future,
            child: const Text('unprepared'),
          ),
        ),
      );
      fonts.completeError(StateError('private raw asset error'));
      await tester.pump();
      expect(
        find.text(
          'Preview fonts unavailable. Restart after checking local assets.',
        ),
        findsOneWidget,
      );
      expect(find.text('unprepared'), findsNothing);
      expect(find.textContaining('private'), findsNothing);
    },
  );
}
