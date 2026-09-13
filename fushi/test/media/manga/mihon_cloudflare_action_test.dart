import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cloudflare_action.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';

class _ChallengeRuntime implements ChallengeMihonRuntime {
  Exception? failure;
  int calls = 0;
  String? lastUserAgent;
  @override
  Future<void> solveCloudflare(Uri uri, {String? userAgent}) async {
    calls++;
    lastUserAgent = userAgent;
    if (failure != null) throw failure!;
  }
}

void main() {
  final MihonCloudflareChallengeException challenge =
      MihonCloudflareChallengeException(
        Uri.parse('https://fixture.invalid/'),
        userAgent: 'FixtureSource/1.0',
      );
  test(
    'finds challenge through library and runtime wrappers without text guessing',
    () {
      expect(
        mihonCloudflareChallenge(
          OnlineMangaUnavailable(
            OnlineMangaUnavailableReason.runtimeFailure,
            'chapters failed',
            cause: MihonRuntimeException('WRAPPED', 'failed', cause: challenge),
          ),
        ),
        same(challenge),
      );
      expect(
        mihonCloudflareChallenge(
          StateError('Cloudflare https://fixture.invalid'),
        ),
        isNull,
      );
    },
  );

  testWidgets('cancel does not retry; subsequent success does', (
    WidgetTester tester,
  ) async {
    final _ChallengeRuntime runtime = _ChallengeRuntime()
      ..failure = const MihonRuntimeException(
        'CHALLENGE_CANCELLED',
        'Cancelled',
      );
    int retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MihonCloudflareAction(
            runtime: runtime,
            error: challenge,
            onVerified: () async {
              retries++;
            },
          ),
        ),
      ),
    );
    expect(runtime.calls, 0);
    await tester.tap(find.text(t.manga_source_cloudflare_verify_title));
    await tester.pumpAndSettle();
    expect(retries, 0);
    expect(find.textContaining('Cancelled'), findsNothing);
    runtime.failure = null;
    await tester.tap(find.text(t.manga_source_cloudflare_verify_title));
    await tester.pumpAndSettle();
    expect(retries, 1);
    expect(runtime.lastUserAgent, 'FixtureSource/1.0');
  });

  testWidgets('failed verification remains visible and never retries', (
    WidgetTester tester,
  ) async {
    final _ChallengeRuntime runtime = _ChallengeRuntime()
      ..failure = const MihonRuntimeException(
        'CHALLENGE_TIMEOUT',
        'Challenge timed out',
      );
    int retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MihonCloudflareAction(
            runtime: runtime,
            error: challenge,
            onVerified: () async {
              retries++;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text(t.manga_source_cloudflare_verify_title));
    await tester.pumpAndSettle();
    expect(retries, 0);
    expect(find.textContaining('Challenge timed out'), findsOneWidget);
  });
}
