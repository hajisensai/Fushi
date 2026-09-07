import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/onboarding/recommended_pack_tutorial_prompt.dart';
import 'package:fushi/src/onboarding/recommended_pack_tutorial_state.dart';

/// No filesystem operations: durable receipts are covered by the non-widget
/// recommended_pack_tutorial_state_test.dart tests.
class _MemoryTutorialState extends RecommendedPackTutorialState {
  _MemoryTutorialState() : super(Directory('unused_tutorial_test_directory'));

  bool pending = true;
  bool dismissed = false;
  bool completed = false;
  int dismissCalls = 0;
  final Completer<void> dismissal = Completer<void>();

  @override
  Future<bool> get shouldPrompt async => pending && !dismissed && !completed;

  @override
  Future<void> dismissPrompt() async {
    dismissCalls++;
    await dismissal.future;
    dismissed = true;
  }

  @override
  Future<void> markImportSucceeded() async {
    pending = true;
  }

  @override
  Future<void> markCompleted() async {
    completed = true;
  }
}

void main() {
  for (final bool start in <bool>[false, true]) {
    testWidgets(
        '${start ? "start" : "skip"} waits for dismissal and does not prompt again',
        (WidgetTester tester) async {
      final _MemoryTutorialState state = _MemoryTutorialState();
      late BuildContext host;
      int starts = 0;
      bool? dismissedAtStart;
      bool? offered;
      await tester.pumpWidget(MaterialApp(home: Builder(
        builder: (BuildContext context) {
          host = context;
          return const Scaffold();
        },
      )));
      Future<void> onStart() async {
        dismissedAtStart = state.dismissed;
        starts++;
      }

      unawaited(showRecommendedPackTutorialPrompt(
        context: host,
        state: state,
        onStart: onStart,
      ).then((bool value) {
        offered = value;
      }));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.byKey(ValueKey<String>(
          start ? 'pack_tutorial_start' : 'pack_tutorial_skip')));
      await tester.pumpAndSettle();
      expect(state.dismissCalls, 1);
      expect(starts, 0);
      expect(offered, isNull);

      // The route must wait for dismissal to finish, even when it is asynchronous.
      state.dismissal.complete();
      await tester.pumpAndSettle();
      expect(offered, isTrue);
      expect(starts, start ? 1 : 0);
      expect(dismissedAtStart, start ? isTrue : isNull);
      expect(state.completed, isFalse);
      expect(find.byType(AlertDialog), findsNothing);

      await state.markImportSucceeded();
      bool? offeredAgain;
      unawaited(showRecommendedPackTutorialPrompt(
        context: host,
        state: state,
        onStart: onStart,
      ).then((bool value) {
        offeredAgain = value;
      }));
      await tester.pumpAndSettle();
      expect(offeredAgain, isFalse);
      expect(starts, start ? 1 : 0);
      expect(dismissedAtStart, start ? isTrue : isNull);
      expect(find.byType(AlertDialog), findsNothing);
    });
  }

  testWidgets('back dismissal does not count as explicit skip or completion',
      (WidgetTester tester) async {
    final _MemoryTutorialState state = _MemoryTutorialState();
    late BuildContext host;
    bool? offered;
    bool started = false;
    await tester.pumpWidget(MaterialApp(home: Builder(
      builder: (BuildContext context) {
        host = context;
        return const Scaffold();
      },
    )));
    unawaited(showRecommendedPackTutorialPrompt(
      context: host,
      state: state,
      onStart: () async {
        started = true;
      },
    ).then((bool value) {
      offered = value;
    }));
    await tester.pumpAndSettle();
    Navigator.of(host).pop();
    await tester.pumpAndSettle();
    expect(offered, isTrue);
    expect(started, isFalse);
    expect(state.dismissCalls, 0);
    expect(state.dismissed, isFalse);
    expect(state.completed, isFalse);
  });
}
