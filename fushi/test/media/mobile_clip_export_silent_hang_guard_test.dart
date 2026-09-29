import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2542 守卫：手机端片段导出「点了没反应，连失败提示都没有」。
///
/// 用户症状是单一的，但根因是一组**静默**：
/// 1. ffmpeg-kit 的 method channel 往返在超时之外 → `run()` 永不返回 → 「导出中」
///    标志永久为真 → 之后每次点击都撞在防重入门上（行为测试见
///    `test/media/video/ffmpeg_kit_session_timeout_test.dart`）。
/// 2. 有声书那道防重入门本身完全静默（视频页同性质的门一直会提示）。
/// 3. 防重入标志置位在 try 之外，而调用点是 `unawaited(...)` → 置位到 try 之间抛
///    出就成了无人接管的异步错误，标志永久为真。
/// 4. 手机端产物落 app 私有目录（不进相册），系统分享面板是唯一取回通道，而分享
///    被静默丢弃时 UI 照样报「已保存」= 假成功。
/// 5. 视频页在 `!mounted` 时把**已成功**的产物删掉且零反馈。
/// 6. 合成层 `inputMissing` / `outputMissing` 零日志 → 用户的错误日志页一片空白。
///
/// 这些出口大多没有可断言的 widget 行为（`unawaited` 的异步管线 + 平台分流），
/// 源码守卫是最强可落地层：回退任何一条即报红。
void main() {
  String libFile(String relative) =>
      File(relative).readAsStringSync().replaceAll('\r\n', '\n');

  group('有声书片段导出不再静默（BUG-2542）', () {
    late String audiobookPart;

    setUpAll(() {
      audiobookPart = libFile(
        'lib/src/pages/implementations/reader_fushi/audiobook.part.dart',
      );
    });

    test('防重入门必须给用户反馈，不得是裸 return', () {
      final int gate = audiobookPart.indexOf('if (_audiobookClipExporting) {');
      expect(gate, greaterThan(-1),
          reason: '防重入门必须带块体（里面要弹提示）；裸 `if (...) return;` 即回归');
      final String body = audiobookPart.substring(gate, gate + 700);
      expect(body, contains('audiobook_export_clip_in_progress'),
          reason: '导出进行中再点，必须复用「正在导出」文案提示，别静默丢弃');
    });

    test('防重入标志与 try/finally 同域：置位后不得再有可抛语句落在 try 之外', () {
      final int setFlag =
          audiobookPart.indexOf('_audiobookClipExporting = true;');
      expect(setFlag, greaterThan(-1));
      final int tryStart = audiobookPart.indexOf('try {', setFlag);
      expect(tryStart, greaterThan(setFlag));

      // 置位与 try 之间只允许不可能抛的局部声明。这三个读取（主题色 / 设置 /
      // Overlay）必须在 try **内**——它们曾在外面，抛出后因调用点是 unawaited
      // 而无人接管，标志永久为真。
      //
      // 匹配**带类型的完整声明**而不是裸符号名：源码注释里会引用这些符号，裸名
      // 匹配会命中解释性注释而不是真正的语句。
      for (final String risky in <String>[
        'final OverlayState? overlay = Overlay.maybeOf(context);',
        'final ReaderThemeColors themeColors = _readerThemeColors;',
        'msg: t.audiobook_export_clip_in_progress,',
      ]) {
        final int at = audiobookPart.indexOf(risky, setFlag);
        expect(at, greaterThan(tryStart),
            reason: '$risky 必须落在 try 之内（置位与 try 之间不得有可抛语句）');
      }
    });

    test('移动端分享失败不得报「已保存」', () {
      expect(audiobookPart, contains('final bool shared = await FushiShare'),
          reason: '必须消费分享返回值；fire-and-forget 就会弹出假成功');
      expect(audiobookPart, contains('audiobook_export_clip_share_unavailable'),
          reason: '面板没呈现时必须给诚实文案，而不是复用 saved');
    });
  });

  group('视频片段导出不再静默（BUG-2542）', () {
    late String clipExportPart;

    setUpAll(() {
      clipExportPart = libFile(
        'lib/src/pages/implementations/video_fushi/clip_export.part.dart',
      );
    });

    test('controller 缺失不得是裸 return', () {
      final int gate = clipExportPart.indexOf('if (controller == null) {');
      expect(gate, greaterThan(-1),
          reason: '`if (controller == null) return;` 是零 OSD 零日志的静默出口');
      expect(clipExportPart.substring(gate, gate + 400),
          contains('video_clip_export_input_missing'));
    });

    test('unmount 时不得删掉已成功的产物，且要留下落点记录', () {
      final int unmounted = clipExportPart.indexOf('if (!mounted) {\n      //');
      expect(unmounted, greaterThan(-1), reason: '导出返回后的 !mounted 分支必须带说明性块体');
      final int nextBranch = clipExportPart.indexOf(
        'if (generation != _clipExportGeneration',
        unmounted,
      );
      expect(nextBranch, greaterThan(unmounted));
      final String body = clipExportPart.substring(unmounted, nextBranch);

      expect(body, contains('if (result.isSuccess)'),
          reason: '成功产物与失败残片必须分开处置：从前一律删，等于丢掉用户等来的文件');
      expect(body, contains('ErrorLogService.instance.log'),
          reason: 'unmount 收场必须留一条可追记录（此前三重静默：无成功、无失败、无日志）');
      final int deleteAt = body.indexOf('_deleteClipOutput');
      final int elseAt = body.indexOf('} else {');
      expect(elseAt, greaterThan(-1));
      expect(deleteAt, greaterThan(elseAt), reason: '删产物只允许出现在 else（导出失败）分支里');
    });

    test('移动端分享失败不得报「已导出」', () {
      expect(clipExportPart, contains('final bool shared = isDesktop ||'),
          reason: '桌面短路 + 移动消费分享返回值；fire-and-forget 就是假成功');
      expect(clipExportPart, contains('video_clip_export_share_unavailable'));

      // 成功文案必须落在 shared 为真的分支里，不能再无条件先弹。
      final int shared =
          clipExportPart.indexOf('final bool shared = isDesktop');
      final int exported =
          clipExportPart.indexOf('video_clip_exported', shared);
      expect(exported, greaterThan(shared), reason: '成功 OSD 必须在拿到分享结果之后才弹');
    });
  });

  group('合成层静默出口补日志（BUG-2542）', () {
    late String synth;

    setUpAll(() {
      synth = libFile('lib/src/media/audiobook/audiobook_clip_export.dart');
    });

    test('inputMissing 记日志并区分缺图/缺音频', () {
      expect(synth, contains('input missing before ffmpeg'));
      // 两个合成变体（单图 / 序列帧）各一条。
      expect(
        RegExp('input missing before ffmpeg').allMatches(synth).length,
        2,
        reason: '单图与序列帧两个合成函数都必须记；漏一个就留一条静默出口',
      );
      expect(synth, contains('framesDir='), reason: '序列帧变体要能区分是帧目录缺还是音频缺');
    });

    test('outputMissing（ffmpeg 报成功却无产物）记日志', () {
      expect(
        RegExp('produced no output file').allMatches(synth).length,
        2,
        reason: '最需要证据的场景，两个变体都不得零日志',
      );
    });
  });

  test('ffmpeg-kit 后端每处平台往返都带超时（BUG-2542 不得回退）', () {
    final String kit = libFile('lib/src/media/video/ffmpeg_kit_backend.dart');
    // 启动 / 取消 / 读退出码 / 读日志四处，各一个上限。
    expect(
        RegExp(r'\.timeout\(').allMatches(kit).length, greaterThanOrEqualTo(4),
        reason: '四处 method channel 往返都必须有上限，任一裸 await 都能让 run() 永不返回');
    expect(kit, contains('KitSessionPhase.start'));
    expect(kit, contains('KitSessionPhase.execute'));
    expect(kit, contains('KitSessionPhase.epilogue'));
    expect(kit, isNot(contains("output: ''")),
        reason: '超时结果不得再返回空 output——那会抹掉「卡在哪」这唯一线索');
  });
}
