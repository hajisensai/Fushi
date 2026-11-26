import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 源码守卫（#3722 c45 遗留，#3816 video-20「复用已读字节」的补漏）：载入链经
/// [_restorePersistedSubtitle] 恢复外挂字幕（合集换集 / 持久化源兜底、导入字幕捷径）
/// 时原先走 `loadCuesForSource`，读盘解析之后没留下对齐判定，[_applyLoad] 的对齐检查
/// 再把同一份字幕整份读一遍（网络盘上多一次整档读）。外挂档必须走
/// `_readSubtitleTextForLoad`（只读一次盘、顺手判对齐产物），与单视频重解析 /
/// sidecar 探测同一口径。media_kit 跑不了 headless，这里锁调用点。
void main() {
  final String src = readVideoFushiSource();

  test('恢复持久化字幕的两条外挂分支都走载入链读法', () {
    final String body = maskComments(
      methodBody(src, '_restorePersistedSubtitle({'),
    );
    final String chosen = maskComments(
      methodBody(src, '_loadChosenSubtitleForLoad(SubtitleSource chosen'),
    );
    final String inherit = maskComments(
      methodBody(src, '_restoreInheritedSubtitle({'),
    );
    for (final String b in <String>[body, chosen, inherit]) {
      expect(b, isNot(contains('loadCuesForSource(')));
    }
    expect(
      RegExp(r'_loadCuesForSourceInLoad\(').allMatches(body),
      hasLength(1),
      reason: '导入字幕捷径一处',
    );
    expect(
      RegExp(r'_loadCuesForSourceInLoad\(').allMatches(chosen),
      hasLength(1),
      reason: '同目录枚举 / 沿用兄弟集选中的源经共用 helper 一处（BUG-5464）',
    );
    expect(body, contains('_loadChosenSubtitleForLoad('));
    expect(inherit, contains('_loadChosenSubtitleForLoad('));
  });

  test('载入链读法：外挂档注入 _readSubtitleTextForLoad，内嵌轨照旧', () {
    final String body = maskComments(
      methodBody(src, 'Future<List<AudioCue>> _loadCuesForSourceInLoad('),
    );
    expect(body, contains('loadExternalSubtitleCueResult('));
    expect(
      body,
      contains('contentReader: (File file) => _readSubtitleTextForLoad('),
    );
    // 内嵌轨仍走缓存 / 抽取（带取消信号），不被外挂读法吞掉。
    expect(body, contains('loadCuesForSource('));
    expect(body, contains('_embeddedSubtitleExtractCancelFor(videoPath)'));
  });
}
