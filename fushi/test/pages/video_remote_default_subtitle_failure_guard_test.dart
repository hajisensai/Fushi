import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 源码守卫：远端 host **默认字幕下载失败不得把整集判成播放失败**。
///
/// `_loadRemoteEpisode` 的 `else if (urls.subtitleUrl != null)` 分支此前没有局部
/// try/catch，`getRemoteVideoSubtitle` 任何非 2xx（飞牛返回 HTML 登录页、Emby 图形轨
/// 抽取 500、旧 host 无该端点）都冒到方法外层 catch → `_failed = true`，而视频流本身
/// 明明能放。同方法里 `embedded:<n>` 重放分支早就是「抽取失败静默落回、不阻断起播」，
/// 默认字幕分支须对齐：失败只 debugPrint，externalSub / cues 保持空，`_applyLoad`
/// 照常起播。
///
/// media_kit 在 headless test 跑不起真播放器（`_applyLoad` 会 new 真
/// `VideoPlayerController`），本页远端播放测试一律是源码层守卫（与
/// video_episode_list_push_aside_guard_test 同范式），故这里断言结构而非驱动 widget。
void main() {
  late String src;
  late String branch;
  setUpAll(() {
    // 注释掩成空白：分支上方的说明注释本身就写着 `_failed = true` 这段历史，
    // 只有代码层的断言才算数（等长掩码，下标可直接回原串切片）。
    src = maskComments(readVideoFushiSource());
    final int start = src.indexOf('} else if (urls.subtitleUrl != null) {');
    expect(start, greaterThan(-1), reason: '应保留 host 默认字幕分支');
    // 分支之后紧跟换集守卫 + _applyLoad；切到守卫为止即整个分支体。
    final int end = src.indexOf(
      'if (seq != _episodeLoadSeq || !mounted) return;',
      start,
    );
    expect(end, greaterThan(start), reason: '分支后应保留换集序号守卫');
    branch = src.substring(start, end);
  });

  test('默认字幕下载包在局部 try/catch 里，失败只 debugPrint', () {
    expect(branch.contains('try {'), isTrue, reason: '默认字幕分支应有局部 try');
    expect(
      branch.contains('client.getRemoteVideoSubtitle('),
      isTrue,
      reason: '下载调用应在该分支内',
    );
    expect(
      branch.indexOf('client.getRemoteVideoSubtitle('),
      greaterThan(branch.indexOf('try {')),
      reason: '下载调用必须落在 try 块内',
    );
    expect(
      RegExp(r'\} catch \(\w+\) \{').hasMatch(branch),
      isTrue,
      reason: '应有局部 catch 吸收字幕下载异常',
    );
    expect(
      branch.contains('debugPrint('),
      isTrue,
      reason: '字幕失败不是吞掉：必须 debugPrint 留痕',
    );
  });

  test('字幕失败不置 _failed，也不设 externalSub / _remoteSubtitlePath', () {
    expect(
      branch.contains('_failed = true'),
      isFalse,
      reason: '字幕下载失败 ≠ 播放失败，分支内不得置失败态',
    );
    // 路径赋值必须在 cue 解析成功之后（同在 try 内）：抛在解析处时字幕菜单不能
    // 显示一个并不存在 / 解析不了的外挂字幕。
    final int cuesAt = branch.indexOf(
      'cues = await _loadExternalSubtitleCues(',
    );
    final int extAt = branch.indexOf('externalSub = subtitle.path;');
    final int pathAt = branch.indexOf('_remoteSubtitlePath = subtitle.path;');
    expect(cuesAt, greaterThan(-1));
    expect(extAt, greaterThan(cuesAt), reason: 'externalSub 应在 cue 解析成功后才赋值');
    expect(
      pathAt,
      greaterThan(cuesAt),
      reason: '_remoteSubtitlePath 应在 cue 解析成功后才赋值',
    );
  });

  test('分支之后仍走换集守卫 → _applyLoad 起播（字幕失败视频照放）', () {
    final int guardAt = src.indexOf(
      'if (seq != _episodeLoadSeq || !mounted) return;',
      src.indexOf('} else if (urls.subtitleUrl != null) {'),
    );
    final int applyAt = src.indexOf('await _applyLoad(', guardAt);
    expect(
      applyAt,
      greaterThan(guardAt),
      reason: '守卫之后应紧接 _applyLoad，字幕失败不阻断起播',
    );
    // 流 URL 协商失败仍是真正的播放失败：方法外层 catch 保留 _failed = true。
    final int outerCatch = src.indexOf(
      "'[VideoFushiPage] remote episode \$index load failed: \$e\\n\$stack'",
    );
    expect(
      outerCatch,
      greaterThan(applyAt),
      reason: '外层 catch 应保留（流 URL / 起播失败仍判失败）',
    );
    final int outerFailed = src.indexOf('_failed = true', outerCatch);
    expect(outerFailed, greaterThan(outerCatch));
    expect(
      outerFailed - outerCatch,
      lessThan(400),
      reason: '外层 catch 应就近置 _failed = true',
    );
  });
}
