import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_subtitle_source.dart';

/// TODO-1302 / BUG-596 源码守卫 + 逻辑单测。
///
/// 根因：YouTube 走 `preresolvedCues` 路径（[video_hibiki_page.dart] 的
/// `_loadRemoteEpisode`）把预解析 cue 直接注入 overlay，却绕过远端字幕轨模型——
/// 不写 `_remoteSubtitlePath`、不加 `_remoteEmbeddedSubtitleTracks`、`_currentSubtitleSource`
/// 留 null → 远端字幕菜单（subtitle.part.dart）渲染不出任何 YouTube 字幕行、且「关闭」
/// 项按 `_isRemote && _currentSubtitleSource == null` 被误显选中，用户根本选不到 YouTube 字幕。
///
/// 修复：应用 preresolvedCues 时把 `_currentSubtitleSource` 设为非空合成源哨兵
/// `_kYoutubeCaptionsSource`，远端菜单据 `_youtubeCaptionsAvailable` 渲染一条「YouTube
/// 字幕」行并高亮，关闭走既有 `_clearRemoteSubtitle`（置 null）。
///
/// VideoHibikiPage 过重（需完整 app + media_kit controller）无法在 widget test 拉起私有
/// 状态与菜单构建，故这里落最强可落地层：① 源码语料守卫（切片两文件断言登记/渲染/符号
/// 定义均在位，删任一即红——同时防上次「引用未定义符号致不编译」回归）；② 真逻辑单测断言
/// 合成哨兵不被 `SubtitleSource.isOff` 误判为「关闭」。
void main() {
  late String pageSrc;
  late String subtitleSrc;
  setUpAll(() {
    String read(String p) =>
        File(p).readAsStringSync().replaceAll('\r\n', '\n');
    pageSrc = read('lib/src/pages/implementations/video_hibiki_page.dart');
    subtitleSrc =
        read('lib/src/pages/implementations/video_hibiki/subtitle.part.dart');
  });

  test('subtitle part defines the synthetic YouTube captions source sentinel',
      () {
    expect(
      subtitleSrc.contains('const String _kYoutubeCaptionsSource = '
          "'youtube:captions';"),
      isTrue,
      reason: 'must define the non-null synthetic YouTube captions sentinel',
    );
  });

  test('preresolvedCues branch registers the YouTube captions source', () {
    // 登记源指针：预解析 cue 分支必须把 _currentSubtitleSource 设成合成哨兵，
    // 否则 _applyLoad 内 externalSubtitlePath==null 会保留 null → 关闭被误选。
    expect(
      pageSrc.contains('cues = client.preresolvedCues;') &&
          pageSrc.contains('_currentSubtitleSource = _kYoutubeCaptionsSource;'),
      isTrue,
      reason: 'preresolvedCues path must register the YouTube captions source',
    );
  });

  test('remote subtitle menu renders + highlights a YouTube captions row', () {
    expect(
        subtitleSrc.contains('_isRemote && _youtubeCaptionsAvailable'), isTrue,
        reason: 'menu must gate a dedicated YouTube captions row');
    expect(subtitleSrc.contains('t.video_subtitle_youtube_captions'), isTrue,
        reason: 'row must use the YouTube captions i18n title key');
    expect(
      subtitleSrc.contains(
          'selected: _currentSubtitleSource == _kYoutubeCaptionsSource'),
      isTrue,
      reason: 'row must highlight when the synthetic sentinel is current',
    );
    expect(subtitleSrc.contains('_applyYoutubeCaptions(controller)'), isTrue,
        reason: 'tapping the row must re-apply the preresolved cues');
  });

  test('referenced getter + helper are defined in the same private scope', () {
    // 防上次失败回归：subtitle.part.dart 引用的 _youtubeCaptionsAvailable /
    // _applyYoutubeCaptions 必须在同一 State 类私有作用域里定义，否则不编译。
    expect(subtitleSrc.contains('bool get _youtubeCaptionsAvailable {'), isTrue,
        reason: 'the availability getter must be defined here');
    expect(
      subtitleSrc.contains(
          'Future<void> _applyYoutubeCaptions(VideoPlayerController controller)'),
      isTrue,
      reason: 'the apply helper must be defined here',
    );
    // 派生自真实客户端的 preresolvedCues，无独立可失步状态。
    expect(
      subtitleSrc.contains('client is UrlStreamVideoClient &&\n'
              '        client.preresolvedCues.isNotEmpty') ||
          subtitleSrc.contains(
              'client is UrlStreamVideoClient && client.preresolvedCues'),
      isTrue,
      reason: 'availability must derive from the client preresolvedCues',
    );
  });

  test('off row selection still gates the remote-null case', () {
    // 「关闭」高亮判据保持 SubtitleSource.isOff(...) || (_isRemote && ...==null)：
    // 有了非空哨兵后，YouTube 字幕激活时 _currentSubtitleSource!=null → 关闭不再被选。
    expect(
      subtitleSrc.contains('SubtitleSource.isOff(_currentSubtitleSource) ||') &&
          subtitleSrc.contains('(_isRemote && _currentSubtitleSource == null)'),
      isTrue,
      reason: 'off row must remain gated on isOff OR remote-null only',
    );
  });

  test('the synthetic sentinel is not treated as an off sentinel', () {
    // 真逻辑：合成哨兵不能被 isOff 误判为「关闭」，否则菜单又把关闭显选中。
    expect(SubtitleSource.isOff('youtube:captions'), isFalse);
    expect(SubtitleSource.isOff(SubtitleSource.offSentinel), isTrue);
    expect(SubtitleSource.isOff(null), isFalse);
  });
}
