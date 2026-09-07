import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/onboarding/recommended_pack_tutorial_state.dart';

void main() {
  late Directory root;
  late RecommendedPackTutorialState state;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pack_tutorial_state');
    state = RecommendedPackTutorialState(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('only successful import schedules a tutorial across restart', () async {
    expect(await state.shouldPrompt, isFalse);
    await state.markImportSucceeded();
    expect(await RecommendedPackTutorialState(root).shouldPrompt, isTrue);
  });

  test('explicit skip remains dismissed after restart and another import',
      () async {
    await state.markImportSucceeded();
    await state.dismissPrompt();
    final RecommendedPackTutorialState restarted =
        RecommendedPackTutorialState(root);
    await restarted.markImportSucceeded();
    expect(await restarted.shouldPrompt, isFalse);
  });

  test('completed tutorials do not prompt after later imports', () async {
    await state.markCompleted();
    await RecommendedPackTutorialState(root).markImportSucceeded();
    expect(await state.shouldPrompt, isFalse);
  });

  test('pack cleanup cannot erase the pending tutorial', () async {
    final Directory pack = Directory('${root.path}/recommended_pack');
    pack.createSync();
    await state.markImportSucceeded();
    await pack.delete(recursive: true);
    expect(await RecommendedPackTutorialState(root).shouldPrompt, isTrue);
  });
}
