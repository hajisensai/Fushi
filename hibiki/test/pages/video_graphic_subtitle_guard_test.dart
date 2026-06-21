import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'video_hibiki_page_source_corpus.dart';

/// 源码守卫：PGS 等**图形内封字幕**的处理（BUG-122）。
///
/// 根因：VCB-Studio 等蓝光压制把字幕封成 PGS 位图轨（`hdmv_pgs_subtitle`），无文字
/// 数据、不做 OCR 就无法转可查词 cue（ffmpeg 抽 srt 直接报 `bitmap to bitmap` 拒绝）。
/// 旧实现把这类轨标成「内嵌」（术语错，应「内封」）、且点击只落通用失败/转圈，用户
/// 既看不到字幕也用不了。
///
/// 修复（用户选定「标注 + 当画面字幕显示」）：
/// 1. 标签术语「内嵌」→「内封」；
/// 2. 菜单对图形轨用 `video_subtitle_graphic_hint` 副标题标注；
/// 3. 选中图形轨走 `selectEmbeddedGraphicTrack`（libmpv 画面渲染）+
///    `video_subtitle_graphic_shown` 提示，不走 loadCues / 加载遮罩；
/// 4. `load()` 经 `renderGraphicStreamIndex` 在进页面/换集时恢复画面渲染。
///
/// media_kit 在 headless test 跑不起真视频 widget（无 libmpv），故用源码扫描守卫，
/// 与 [video_subtitle_loading_overlay_guard_test] 同范式。
void main() {
  String read(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), isTrue, reason: '源文件应存在: $rel');
    return f.readAsStringSync();
  }

  test('字幕标签术语用「内封」而非「内嵌」（BUG-122）', () {
    final String src = read('lib/src/media/video/video_subtitle_source.dart');
    // _embeddedLabel 生成的菜单标签前缀必须是「内封 N: 」。
    expect(
      src.contains(r"StringBuffer('内封 ${track.streamIndex}: ')"),
      isTrue,
      reason: '_embeddedLabel 应生成「内封 N: 」前缀',
    );
    // 不应再用「内嵌 N」当用户可见标签前缀。
    expect(
      src.contains(r"'内嵌 ${track.streamIndex}"),
      isFalse,
      reason: '不应再有「内嵌 N」标签前缀',
    );
    // isGraphicEmbedded 判据存在。
    expect(src.contains('bool get isGraphicEmbedded'), isTrue);
  });

  test('控制器有图形轨画面渲染入口 + load 恢复参数', () {
    final String src = read('lib/src/media/video/video_player_controller.dart');
    expect(
      src.contains('Future<bool> selectEmbeddedGraphicTrack(int streamIndex)'),
      isTrue,
      reason: '应有把图形轨交给 libmpv 渲染的方法',
    );
    expect(
      src.contains('int? renderGraphicStreamIndex'),
      isTrue,
      reason: 'load() 应支持恢复图形轨画面渲染',
    );
    // 图形分支与文本自动抽取互斥（renderGraphicStreamIndex 优先）。
    expect(
      src.contains('if (renderGraphicStreamIndex != null)'),
      isTrue,
      reason: '恢复图形选择应与文本 cue 自动加载互斥',
    );
  });

  test('视频页：图形轨标注 + 走画面渲染分支（不走加载遮罩）', () {
    final String src = readVideoHibikiSource();
    // 菜单对图形轨标注。
    expect(src.contains('source.isGraphicEmbedded'), isTrue);
    expect(src.contains('t.video_subtitle_graphic_hint'), isTrue,
        reason: '菜单应对图形轨显示「画面显示·不可查词」副标题');
    // 选中图形轨走画面渲染 + 专用提示。
    expect(src.contains('controller.selectEmbeddedGraphicTrack('), isTrue);
    expect(src.contains('t.video_subtitle_graphic_shown'), isTrue);
    // 恢复路径透传 streamIndex。
    expect(src.contains('renderGraphicStreamIndex'), isTrue,
        reason: '恢复路径应把图形 streamIndex 透传给 _applyLoad/load');
    expect(src.contains('graphicStreamIndex'), isTrue);
  });

  test('图形分支在加载遮罩之前 return，不弹遮罩（瞬时切轨）', () {
    final String src = readVideoHibikiSource();
    final int start = src.indexOf('Future<bool> _selectSubtitleSource(');
    expect(start, greaterThan(-1));
    final int graphicAt = src.indexOf('if (source.isGraphicEmbedded)', start);
    final int showAt = src.indexOf('_showSubtitleLoadingOverlay();', start);
    expect(graphicAt, greaterThan(start));
    expect(showAt, greaterThan(graphicAt),
        reason: '图形分支应在加载遮罩之前处理并 return，避免给瞬时切轨弹遮罩');
  });
}
