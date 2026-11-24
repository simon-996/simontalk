// Built only by the isolated Chromium / PostgreSQL integration test.
import 'dart:convert';
import 'dart:js_interop';

import 'package:http/http.dart' as http;
import 'package:simontalk_client/core/api_client.dart';
import 'package:simontalk_client/core/http_client_web.dart';
import 'package:simontalk_client/core/token_store.dart';
import 'package:simontalk_client/features/practice/practice_models.dart';
import 'package:simontalk_client/features/realtime/browser_media_session_web.dart';

@JS('mediaObservation')
external String _observation();

@JS('simulatePageHide')
external void _hide();

Future<void> main() async {
  final root = Uri.base;
  Object? atQuarantine;
  Future<void> report(String reason) => http.post(
    root.resolve('/result'),
    body: jsonEncode({
      'reason': reason,
      'at_quarantine': atQuarantine,
      'media': jsonDecode(_observation()),
    }),
  );
  try {
    final fixture = jsonDecode((await http.get(root.resolve('/fixture'))).body);
    final api = ApiClient(
      baseUrl: root,
      isWeb: true,
      tokenStore: CookieTokenStore(),
      client: createHttpClient(),
    )..expectedAccountId = fixture['account'];
    final session = BrowserMediaSession(
      api: api,
      accountId: fixture['account'],
      connection: ConnectionReservation.fromJson(fixture['connection']),
      onEvent: (kind, payload) {
        if (kind == 'quarantine' && payload == 'response_a') {
          atQuarantine = jsonDecode(_observation());
          switch (fixture['ending']) {
            case 'account':
              api.expectedAccountId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
            case 'hidden':
              _hide();
            case 'disconnect':
              http.post(root.resolve('/disconnect'));
          }
        }
      },
      onClosed: report,
    );
    await session.start();
  } on Object {
    await report('startup_failed');
  }
}
