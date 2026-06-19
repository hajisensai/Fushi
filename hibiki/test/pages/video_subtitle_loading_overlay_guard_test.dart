import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：切换内嵌字幕时，抽取期间必须有加载遮罩（BUG-104）。
///
/// 根因：内嵌字幕要从容器里 ffmpeg demux 抽取；27GB BluRay REMUX 这类大文件首次
/// 抽取可达 ~20s。原实现 `_selectSubtitleSource` 直接 `await loadCuesForSource`，
/// 底栏菜单一关、画面字幕没变、整段无任何反馈 → 用户读作「点了没切换过去」。
/// 修复：抽取前后包一层不可关的加载遮罩，并把抽取改为单趟全轨缓存（同视频后续切换
/// 瞬时命中）。
///
/// 用源码扫描守卫：media_kit 在 headless test 跑不起来真视频 widget（与
/// [video_lookup_resume_static_test] / [video_mobile_controls_static_test] 同理），
/// 故断言源码层的遮罩配对与 try/finally 包裹结构。
void main() {
  final File page = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  );

  late String src;
  setUpAll(() {
    expect(page.existsSync(), isTrue, reason: '视频页源文件应存在');
    src = page.readAsStringSync();
  });

  test('定义了配对的加载遮罩 show/hide 方法', () {
    expect(
      src.contains('void _showSubtitleLoadingOverlay()'),
      isTrue,
      reason: '应有弹出字幕抽取加载遮罩的方法',
    );
    expect(
      src.contains('void _hideSubtitleLoadingOverlay()'),
      isTrue,
      reason: '应有关闭字幕抽取加载遮罩的方法',
    );
  });

  test('抽取期间面板不可交互（行 disabled + 进度圈），等价旧不可关遮罩', () {
    // TODO-274：加载从独立 barrier dialog 迁到字幕源 side panel —— 抽取期间靠
    // [_subtitleLoadingShown] 标记把面板所有行 `enabled: !_subtitleLoadingShown`
    // 置灰（点不动 = 不可关/不可误触），并显示进度圈，与旧 barrierDismissible:false
    // 遮罩同义。
    expect(src.contains('enabled: !_subtitleLoadingShown'), isTrue,
        reason: '抽取期间面板行必须 disabled，避免中途误触切别的源');
    expect(src.contains('CircularProgressIndicator'), isTrue);
    expect(src.contains('LinearProgressIndicator'), isTrue,
        reason: '面板抽取期显示进度条');
  });

  test('_selectSubtitleSource 在抽取前后包裹遮罩（show…try/finally hide）', () {
    // 截取 _selectSubtitleSource 方法体，断言遮罩 show 在 loadCuesForSource 之前、
    // hide 在 finally 里，保证任何返回/异常路径都会收起遮罩、不留死遮罩。
    final int start = src.indexOf('Future<bool> _selectSubtitleSource(');
    expect(start, greaterThan(-1), reason: '应有 _selectSubtitleSource 方法');
    final int loadAt =
        src.indexOf('loadCuesForSource(source, videoPath', start);
    expect(loadAt, greaterThan(start));

    final int showAt = src.indexOf('_showSubtitleLoadingOverlay();', start);
    expect(showAt, greaterThan(start));
    expect(showAt, lessThan(loadAt), reason: '遮罩必须在抽取开始前弹出');

    final String afterShow = src.substring(showAt, loadAt + 200);
    expect(afterShow.contains('try {'), isTrue, reason: '抽取应在 try 块内');
    expect(afterShow.contains('} finally {'), isTrue,
        reason: '遮罩应在 finally 中收起');
    expect(afterShow.contains('_hideSubtitleLoadingOverlay();'), isTrue,
        reason: 'finally 必须调用 hide，避免任何路径残留死遮罩');
  });

  test('防重复弹出/错误 pop 的状态位', () {
    expect(src.contains('bool _subtitleLoadingShown'), isTrue);
  });

  test('_applyLoad 成功打开视频后后台预抽文本内封字幕缓存（TODO-011）', () {
    final int start = src.indexOf('Future<void> _applyLoad({');
    expect(start, greaterThan(-1), reason: '应有 _applyLoad 方法');
    final int seedAt = src.indexOf('_seedWarmPopup();', start);
    final int watchAt =
        src.indexOf('if (!_isRemote && _watchTracker == null)', start);
    final int prewarmAt = src.indexOf(
        'unawaited(prewarmEmbeddedSubtitleCache(videoPath));', start);
    expect(prewarmAt, greaterThan(seedAt), reason: '预抽应在视频打开成功后的 warmup 区域触发');
    expect(prewarmAt, lessThan(watchAt),
        reason: '预抽不应混进统计初始化，保持 fire-and-forget 入口清晰');
    expect(src.substring(seedAt, prewarmAt), contains('if (videoPath != null)'),
        reason: '远程流没有本地容器文件，不应触发内封字幕预抽');
  });

  test('TODO-572: controller 内封字幕首载经协调器做就绪后重试，不退回弱判据/单次', () {
    // 根因：首开三方 IO 争用→ffmpeg -i 枚举超时→0 轨→当「无内封字幕」处理，
    // 退出重开才出来。修复：load() 把 player+loadToken 传给 _loadEmbeddedSubtitleIfNeeded，
    // 后者经 loadDefaultTextEmbeddedSubtitleCuesWithReadinessRetry 在瞬态失败时等
    // 字幕轨真实就绪后重试一次，过期判据用 _isCurrentLoad(player, loadToken) 双判据。
    final File controller = File(
      'lib/src/media/video/video_player_controller.dart',
    );
    expect(controller.existsSync(), isTrue, reason: '控制器源文件应存在');
    final String csrc = controller.readAsStringSync();

    // load() 触发时必须传 player + loadToken（不再是弱判据的无参触发）。
    expect(
      csrc.contains('unawaited(_loadEmbeddedSubtitleIfNeeded(\n'
          '        player: player,\n'
          '        loadToken: loadToken,'),
      isTrue,
      reason: 'load() 触发内封字幕自动加载必须传 player + loadToken，供过期判据与就绪重试',
    );

    // 自动加载经协调器，且就绪等待用 libmpv 字幕轨就绪信号、过期判据用双判据。
    final int start =
        csrc.indexOf('Future<void> _loadEmbeddedSubtitleIfNeeded({');
    expect(start, greaterThan(-1), reason: '应有 _loadEmbeddedSubtitleIfNeeded');
    // 跳过命名参数列表，从函数体起始花括号（`}) async {`）开始做花括号配对，
    // 否则会在参数列表的 `{` 处就提前闭合，截不到方法体。
    final int bodyOpen = csrc.indexOf('}) async {', start);
    expect(bodyOpen, greaterThan(start), reason: '应能定位方法体起始');
    final int open = csrc.indexOf('{', bodyOpen);
    int depth = 0;
    int end = csrc.length;
    for (int i = open; i < csrc.length; i++) {
      if (csrc[i] == '{') {
        depth++;
      } else if (csrc[i] == '}') {
        depth--;
        if (depth == 0) {
          end = i + 1;
          break;
        }
      }
    }
    final String body = csrc.substring(start, end);

    expect(
      body.contains('loadDefaultTextEmbeddedSubtitleCuesWithReadinessRetry('),
      isTrue,
      reason: '必须经就绪重试协调器加载，而非单次 loadDefaultTextEmbeddedSubtitleCues',
    );
    expect(
      body.contains(
          'waitForReady: () => _waitUntilSubtitleTracksReady(player)'),
      isTrue,
      reason: '就绪信号必须是 libmpv 字幕轨就绪（容器已 demux），而非固定延迟',
    );
    expect(
      body.contains('isStillCurrent: () => _isCurrentLoad(player, loadToken)'),
      isTrue,
      reason: '过期判据必须是 player identity + loadToken 双判据，防换片误挂旧字幕',
    );
    expect(
      body.contains('await loadDefaultTextEmbeddedSubtitleCues('),
      isFalse,
      reason: '不应再在控制器里直接单次调用，统一走协调器',
    );
  });
}
