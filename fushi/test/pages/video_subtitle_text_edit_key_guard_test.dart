// BUG-4821：字幕手改的存储键（视频 + 字幕源）必须在弹输入框之前取。输入框开着的时候
// 字幕源可能被换掉（整轨转文字 / ASR 恰好完成并换源）；关闭后再取键，这条改动就存到
// 新源名下——原来那条字幕没改成，新源里多一条对不上的覆盖。
//
// 源码守卫：编辑流程挂在整页 State 的 part 上，起整页做 widget 测试要带播放器与库，
// 这里钉住「键先于任何 await 取、保存只用传进来的键」这两条结构性质。
import 'dart:io';

import 'package:test/test.dart';

String _memberSource(String source, String signature) {
  final int start = source.indexOf(signature);
  expect(start, isNonNegative, reason: 'missing $signature');
  final int next = source.indexOf('\n  }\n', start);
  expect(next, isNonNegative, reason: 'unterminated $signature');
  return source.substring(start, next);
}

void main() {
  final String source = File(
    'lib/src/pages/implementations/video_fushi/subtitle_text_edit.part.dart',
  ).readAsStringSync();

  test('编辑字幕：存储键在第一个 await（暂停 / 弹输入框）之前取，并原样交给保存', () {
    final String edit = _memberSource(
      source,
      'Future<void> _editCueText(AudioCue cue) async {',
    );
    final int keys = edit.indexOf(
      'final _SubtitleTextOverrideKeys keys = _subtitleTextOverrideKeys;',
    );
    expect(keys, isNonNegative);
    expect(keys, lessThan(edit.indexOf('await ')));
    expect(keys, lessThan(edit.indexOf('showFushiTextInputDialog(')));
    expect(edit, contains('await _saveCueTextOverride(cue, edited, keys);'));
  });

  test('保存只用调用方给的键，不在写库时重新读「当前源」', () {
    final String save = _memberSource(
      source,
      'Future<void> _saveCueTextOverride(',
    );
    expect(save, contains('final String videoKey = keys.videoKey;'));
    expect(save, contains('final String sourceKey = keys.sourceKey;'));
    expect(save, isNot(contains('_subtitleTextOverrideVideoKey')));
    expect(save, isNot(contains('_subtitleTextOverrideSourceKey')));
    // 写完时当前层已经换了就不重读（当前层没有变化）。
    expect(save, contains('if (keys == _subtitleTextOverrideKeys) {'));
  });
}
