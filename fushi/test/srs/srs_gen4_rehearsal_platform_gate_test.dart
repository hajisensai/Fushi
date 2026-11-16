// 存储换代后台预演（设计 §8 G4b）只在桌面自动跑：对拍峰值（约 440 MB）压进 D4 内存目标之前不上手机。判据只在
// fushi_engine 的 srs_gen4_rehearsal.dart 写一次（srsGen4RehearsalAutoRunsOn），app 的运行时在开节拍与每次判空闲时
// 都问它，不散写 Platform.isXxx。
import 'dart:io';

import 'package:test/test.dart';
import 'package:fushi_engine/srs/sync2/srs_gen4_rehearsal.dart';

void main() {
  test('the platform gate is desktop only', () {
    for (final String os in <String>['windows', 'macos', 'linux']) {
      expect(srsGen4RehearsalAutoRunsOn(os), isTrue, reason: os);
    }
    for (final String os in <String>['android', 'ios']) {
      expect(srsGen4RehearsalAutoRunsOn(os), isFalse, reason: os);
    }
  });

  test('the app runtime asks the gate before starting and before each run', () {
    final String src = File(
      'lib/src/srs/srs_app_runtime.dart',
    ).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
    expect(src, contains('if (srsGen4RehearsalAutoRuns) rehearsal.start();'));
    expect('rehearsal.start()'.allMatches(src), hasLength(1));
    final int at = src.indexOf('SrsGen4RehearsalScheduler rehearsal =');
    expect(at, isNot(-1));
    final String ctor = src.substring(at, src.indexOf(');', at));
    expect(ctor, contains('canRunNow: () => srsGen4RehearsalAutoRuns &&'));
    expect(ctor, isNot(contains('Platform.')));
  });
}
