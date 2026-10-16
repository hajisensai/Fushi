import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'video_fushi_page_source_corpus.dart';

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
    final String src = read(
      '../packages/fushi_engine/lib/media/video/video_subtitle_source.dart',
    );
    // embeddedSubtitleTrackLabel 生成的菜单标签前缀必须是「内封 N: 」（TODO-844
    // 后改用 parts.join，但前缀文案不变）。
    expect(
      src.contains(r"'内封 ${track.streamIndex}: ${parts.join(' / ')}'"),
      isTrue,
      reason: 'embeddedSubtitleTrackLabel 应生成「内封 N: 」前缀',
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
    // 首个位置参数仍是轨序号；可选的 `timingInput` 指定逐句时间表的整轨来源（互联
    // host 回传的整轨等，缺省按播放源推导）——不许变成必填、也不许丢掉轨序号。
    expect(
      RegExp(
        r'Future<bool> selectEmbeddedGraphicTrack\(\s*int streamIndex,\s*\{\s*'
        r'GraphicSubtitleTimingInput\? timingInput,\s*\}\)',
      ).hasMatch(src),
      isTrue,
      reason: '应有把图形轨交给 libmpv 渲染的方法（轨序号 + 可选整轨时间表来源）',
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
    final String src = readVideoFushiSource();
    // 菜单对图形轨标注。
    expect(src.contains('source.isGraphicEmbedded'), isTrue);
    expect(
      src.contains('t.video_subtitle_graphic_learning_hint'),
      isTrue,
      reason: '菜单应说明图形轨暂停后经 OCR 点字查词，并引导外挂文字字幕或 ASR 以求更准',
    );
    // 选中图形轨走画面渲染 + 专用提示。
    expect(src.contains('controller.selectEmbeddedGraphicTrack('), isTrue);
    expect(src.contains('t.video_subtitle_graphic_shown'), isTrue);
    // 恢复路径透传 streamIndex。
    expect(
      src.contains('renderGraphicStreamIndex'),
      isTrue,
      reason: '恢复路径应把图形 streamIndex 透传给 _applyLoad/load',
    );
    expect(src.contains('graphicStreamIndex'), isTrue);
  });

  test('视频页：图形轨有「整轨 OCR 成文字字幕」入口并当外挂字幕加载', () {
    final String src = readVideoFushiSource();
    final int tile = src.indexOf('Text(t.video_subtitle_graphic_ocr_track)');
    expect(tile, greaterThan(-1), reason: '图形轨行下应有整轨 OCR 按钮');
    expect(
      src.indexOf(
        '_generateSubtitleFromGraphicTrack(controller, source)',
        tile,
      ),
      greaterThan(tile),
      reason: '按钮应触发整轨 OCR',
    );
    // 本地入口：取数与控制器逐句时间表同一口径，再交共用流程。
    final int local = src.indexOf(
      'Future<void> _generateSubtitleFromGraphicTrack(',
    );
    expect(local, greaterThan(-1));
    final String localBody = src.substring(
      local,
      src.indexOf('\n  }\n', local),
    );
    expect(
      RegExp(
        r'_graphicTrackOcrInput\(\s*controller,\s*source,?\s*\)',
      ).hasMatch(localBody),
      isTrue,
    );
    expect(localBody.contains('_runGraphicTrackOcr('), isTrue);
    // 取数口径：图形轨 + 可解码编码（PGS / VobSub / DVB）+ 控制器推导出的输入。
    final int inputAt = src.indexOf(
      'GraphicSubtitleTimingInput? _graphicTrackOcrInput(',
    );
    expect(inputAt, greaterThan(-1));
    final String inputBody = src.substring(
      inputAt,
      src.indexOf('\n  }\n', inputAt),
    );
    expect(
      inputBody.contains('graphicSubtitleTrackOcrSupportsCodec(source.codec)'),
      isTrue,
    );
    expect(
      inputBody.contains('controller.graphicSubtitleTimingInputForTrack('),
      isTrue,
    );
    final int method = src.indexOf('Future<void> _runGraphicTrackOcr(');
    expect(method, greaterThan(-1));
    final String body = src.substring(method, src.indexOf('\n  }\n', method));
    // 取整轨载荷（带编码的抽轨 / host 整轨）→ 按轨头解码 → 识别（AI 重读与漫画同一
    // 引擎装配）→ SRT。
    for (final String step in <String>[
      'materializeGraphicSubtitleTrack(',
      'readGraphicSubtitleTrackInBackground(',
      // 引擎装配同暂停 OCR，只多带字幕轨语言（低置信度交大模型时的期望语言）与
      // 桌面 CLI 的无头同意答案（null = app 内弹框询问）。
      '_prepareGraphicSubtitleOcr(dir, language: language, consent: consent)',
      // 边抽边识别：识别出的字实时补进可点字幕。
      'recognizeGraphicSubtitleCuesLive(',
      'controller.setCues(live)',
      'buildGraphicSubtitleSrt(',
      // 产物与 ASR 同口径：当外挂文字字幕加载，播放中即可点字查词（本地入口传
      // `_importExternalSubtitle`，远端入口传 `_applyRemoteSubtitle`）。
      'await applyResult(target);',
      'on GraphicSubtitleOcrUnavailable',
      'await session.close();',
    ]) {
      expect(body.contains(step), isTrue, reason: '整轨 OCR 缺少步骤：$step');
    }
    // 取消判据：换集 / 换播放器 / 离开页面即停。
    expect(body.contains('isCancelled: () => !isCurrent()'), isTrue);
    expect(
      RegExp(
        r'applyResult: \(String target\) =>\s*_importExternalSubtitle\(controller, target\)',
      ).hasMatch(localBody),
      isTrue,
    );
  });

  test('远端图形轨也有整轨 OCR 入口：互联下 host 整轨、其它按流地址 + 请求头', () {
    final String src = readVideoFushiSource();
    expect(
      RegExp(
        r'_generateSubtitleFromRemoteGraphicTrack\(\s*controller,\s*track,?\s*\)',
      ).hasMatch(src),
      isTrue,
      reason: '远端字幕轨行下应有整轨 OCR 按钮',
    );
    final int at = src.indexOf(
      'GraphicSubtitleTimingInput? _remoteGraphicTrackOcrInput(',
    );
    expect(at, greaterThan(-1));
    final String body = src.substring(at, src.indexOf('\n  }\n', at));
    // 互联：下载 host 抽好的整轨，绝不读整片流。
    expect(
      body.contains('client is RemoteVideoGraphicSubtitleTrackFetch'),
      isTrue,
    );
    expect(body.contains('buildRemoteGraphicSubtitleTimingInput('), isTrue);
    // 媒体服务器 / URL 流：控制器同一口径（流地址 + 播放会话请求头）。
    expect(
      body.contains('controller.graphicSubtitleTimingInputForTrack('),
      isTrue,
    );
    // 互联分支必须先于流地址分支 return。
    expect(
      body.indexOf('buildRemoteGraphicSubtitleTimingInput('),
      lessThan(body.indexOf('controller.graphicSubtitleTimingInputForTrack(')),
    );
    final int run = src.indexOf(
      'Future<void> _generateSubtitleFromRemoteGraphicTrack(',
    );
    final String runBody = src.substring(run, src.indexOf('\n  }\n', run));
    expect(runBody.contains('_runGraphicTrackOcr('), isTrue);
    expect(
      runBody.contains('_applyRemoteSubtitle(controller, target)'),
      isTrue,
    );
  });

  test('图形分支在加载遮罩之前 return，不弹遮罩（瞬时切轨）', () {
    final String src = readVideoFushiSource();
    final int start = src.indexOf('Future<bool> _selectSubtitleSource(');
    expect(start, greaterThan(-1));
    final int graphicAt = src.indexOf('if (source.isGraphicEmbedded)', start);
    final int showAt = src.indexOf('_showSubtitleLoadingOverlay();', start);
    expect(graphicAt, greaterThan(start));
    expect(
      showAt,
      greaterThan(graphicAt),
      reason: '图形分支应在加载遮罩之前处理并 return，避免给瞬时切轨弹遮罩',
    );
  });
}
