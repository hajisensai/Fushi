import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 源码守卫：切换内嵌字幕时，抽取期间必须有加载遮罩（BUG-104）。
///
/// 根因：内嵌字幕要从容器里 ffmpeg demux 抽取；27GB BluRay REMUX 这类大文件首次
/// 抽取可达 ~20s。原实现 `_selectSubtitleSource` 直接 `await loadCuesForSource`，
/// 底栏菜单一关、画面字幕没变、整段无任何反馈 → 用户读作「点了没切换过去」。
/// 修复：抽取前后包一层不可关的加载遮罩，并把抽取改为单趟全轨缓存（同视频后续切换
/// 瞬时命中）。
///
/// 反馈 ZTDA2WQJj4 之后：内封文本轨的整轨抽取在慢盘上一分钟以上，锁住整个菜单等于把
/// 用户关在里面。内封分支改成不锁菜单——借播放器解码即时出字，面板顶部挂一行「正在
/// 读取完整字幕」+ 停止按钮；外挂文件解析很快，仍用置灰面板的加载状态。「抽取期间必须
/// 有反馈、任何路径都要收起」这条不变。
///
/// 用源码扫描守卫：media_kit 在 headless test 跑不起来真视频 widget（与
/// [video_lookup_resume_static_test] / [video_mobile_controls_static_test] 同理），
/// 故断言源码层的遮罩配对与 try/finally 包裹结构。
void main() {
  late String src;
  setUpAll(() {
    src = readVideoFushiSource();
  });

  test('定义了配对的加载遮罩 show/hide 方法', () {
    expect(
      src.contains('void _showSubtitleLoadingOverlay({'),
      isTrue,
      reason: '应有弹出字幕抽取加载遮罩的方法',
    );
    expect(
      src.contains('void _hideSubtitleLoadingOverlay()'),
      isTrue,
      reason: '应有关闭字幕抽取加载遮罩的方法',
    );
  });

  test('加载状态期间面板不可交互（行 disabled + 进度圈），等价旧不可关遮罩', () {
    // TODO-274：加载从独立 barrier dialog 迁到字幕源 side panel —— 抽取期间靠
    // [_subtitleLoadingShown] 标记把面板所有行 `enabled: !_subtitleLoadingShown`
    // 置灰（点不动 = 不可关/不可误触），并显示进度圈，与旧 barrierDismissible:false
    // 遮罩同义。
    expect(
      src.contains('enabled: !_subtitleLoadingShown'),
      isTrue,
      reason: '抽取期间面板行必须 disabled，避免中途误触切别的源',
    );
    expect(src.contains('CircularProgressIndicator'), isTrue);
    expect(
      src.contains('LinearProgressIndicator'),
      isTrue,
      reason: '面板抽取期显示进度条',
    );
  });

  test('_selectSubtitleSource：外挂分支包加载状态，内封分支用可停止的读取行，两者都在 finally 收起', () {
    // 两个分支各有一种「加载中」反馈，都必须在 finally 里收起——任何返回 / 异常路径都
    // 不留死状态：
    //  - 外挂文件（解析很快）：show…try/finally hide，期间面板行置灰；
    //  - 内封文本轨（整轨抽取，慢盘一分钟以上）：不锁菜单，抽取真正开始时
    //    （onExtractionStarted）挂上「正在读取完整字幕」行，finally 撤下。
    // 上界=方法体的右花括号（花括号配对），不用定长窗口。
    final String method = methodBody(
      src,
      'Future<bool> _selectSubtitleSource(',
    );

    // 内封分支：带取消信号的那次调用。
    final int embeddedLoadAt =
        RegExp(
          r'loadSubtitleCueResult\(\s*source,\s*videoPath,\s*bookUid,\s*cancel:',
        ).firstMatch(method)?.start ??
        -1;
    expect(embeddedLoadAt, greaterThan(-1), reason: '缺内封轨的可取消抽取调用');
    final int showAt = method.indexOf(
      '_showSubtitleLoadingOverlay(origin: origin);',
    );
    expect(showAt, greaterThan(-1), reason: '缺外挂分支的加载状态 show 调用');
    expect(
      showAt,
      greaterThan(embeddedLoadAt),
      reason: '内封抽取期间不得锁菜单：加载状态只属于其后的外挂分支',
    );

    final String embedded = method.substring(
      method.lastIndexOf('try {', embeddedLoadAt),
      showAt,
    );
    final int rowShownAt = embedded.indexOf(
      '_primaryEmbeddedFullLoad = _EmbeddedTextFullLoad(',
    );
    final int embeddedFinallyAt = embedded.indexOf('} finally {');
    expect(
      embedded.indexOf('onExtractionStarted:'),
      greaterThan(-1),
      reason: '读取行要等抽取真正开始（缓存未命中）才挂',
    );
    expect(rowShownAt, greaterThan(-1), reason: '抽取开始时应挂上读取行');
    expect(
      embeddedFinallyAt,
      greaterThan(rowShownAt),
      reason: '内封抽取应在 try 块内，读取行在 finally 撤下',
    );
    expect(
      embedded.substring(embeddedFinallyAt),
      contains('_primaryEmbeddedFullLoad = null'),
      reason: 'finally 必须撤下读取行，避免任何路径残留一行永远在转的「正在读取」',
    );

    // 外挂分支：show 之后才出现的 try / 抽取 / finally / hide。
    final String afterShow = method.substring(showAt);
    final int tryAt = afterShow.indexOf('try {');
    final int externalLoadAt = afterShow.indexOf(
      'loadSubtitleCueResult(source, videoPath, bookUid);',
    );
    final int finallyAt = afterShow.indexOf('} finally {');
    final int hideAt = afterShow.indexOf('_hideSubtitleLoadingOverlay();');
    expect(tryAt, greaterThan(-1), reason: '外挂解析应在 try 块内');
    expect(externalLoadAt, greaterThan(tryAt), reason: '加载状态必须在解析开始前弹出');
    expect(
      finallyAt,
      greaterThan(externalLoadAt),
      reason: '加载状态应在 finally 中收起',
    );
    expect(
      hideAt,
      greaterThan(finallyAt),
      reason: 'finally 必须调用 hide，避免任何路径残留死遮罩',
    );
  });

  test('_selectSecondarySubtitleSource：内封分支的读取行同样在 finally 撤下', () {
    final String method = methodBody(
      src,
      'Future<bool> _selectSecondarySubtitleSource(',
    );
    final int rowShownAt = method.indexOf(
      '_secondaryEmbeddedFullLoad = _EmbeddedTextFullLoad(',
    );
    expect(rowShownAt, greaterThan(-1), reason: '抽取开始时应挂上读取行');
    final int finallyAt = method.indexOf('} finally {', rowShownAt);
    final int showAt = method.indexOf('_showSubtitleLoadingOverlay(');
    expect(finallyAt, greaterThan(rowShownAt));
    expect(showAt, greaterThan(finallyAt), reason: '内封抽取期间不得锁菜单');
    expect(
      method.substring(finallyAt, showAt),
      contains('_secondaryEmbeddedFullLoad = null'),
      reason: 'finally 必须撤下读取行',
    );
  });

  test('防重复弹出/错误 pop 的状态位', () {
    expect(src.contains('bool _subtitleLoadingShown'), isTrue);
  });

  test('_applyLoad 成功打开视频后后台预抽文本内封字幕缓存（TODO-011）', () {
    final int start = src.indexOf('Future<void> _applyLoad({');
    expect(start, greaterThan(-1), reason: '应有 _applyLoad 方法');
    final int seedAt = src.indexOf('_seedWarmPopup();', start);
    // 锚点跟随真实判据：BUG-2587 起统计采集器按本页身份建（远端也采集），
    // 不再有 _bookRow / !_isRemote 门。
    final int watchAt = src.indexOf(
      'final (String uid, int episodeIndex) = _watchStatsIdentity;',
      start,
    );
    // BUG-4838：调用多了取消信号参数，按调用形状（不看换行）找。
    final int prewarmAt = RegExp(
      r'unawaited\(\s*prewarmEmbeddedSubtitleCache\(\s*videoPath,',
    ).allMatches(src).firstWhere((Match m) => m.start > start).start;
    expect(prewarmAt, greaterThan(seedAt), reason: '预抽应在视频打开成功后的 warmup 区域触发');
    expect(
      prewarmAt,
      lessThan(watchAt),
      reason: '预抽不应混进统计初始化，保持 fire-and-forget 入口清晰',
    );
    expect(
      src.substring(seedAt, prewarmAt).replaceAll(RegExp(r'\s+'), ''),
      contains('if(videoPath!=null&&!controller.isBlurayNavigationSession)'),
      reason: '普通本地视频仍预抽；远端无容器、原盘导航可能读加密文件，均不得预抽',
    );
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
      RegExp(
        r'unawaited\(\s*_loadEmbeddedSubtitleIfNeeded\(\s*'
        r'player:\s*player,\s*loadToken:\s*loadToken,',
      ).hasMatch(csrc),
      isTrue,
      reason: 'load() 触发内封字幕自动加载必须传 player + loadToken，供过期判据与就绪重试',
    );

    // 自动加载经协调器，且就绪等待用 libmpv 字幕轨就绪信号、过期判据用双判据。
    // 这里原来手写了一份花括号配对（含「跳过命名参数表的 `{`」补丁），但它在**原串**
    // 上数括号：注释或字符串里的 `{` / `}` 一样参与配对，方法体里出现一句
    // `// 这里 } 收口` 就会提前闭合。共享 methodBody 先做词法掩码再配对，
    // 参数表圆括号也由它统一跳过，语义相同且不再被注释带偏。
    final String body = methodBody(
      csrc,
      'Future<void> _loadEmbeddedSubtitleIfNeeded({',
    );

    expect(
      body.contains('loadDefaultTextEmbeddedSubtitleCuesWithReadinessRetry('),
      isTrue,
      reason: '必须经就绪重试协调器加载，而非单次 loadDefaultTextEmbeddedSubtitleCues',
    );
    expect(
      body.contains(
        'waitForReady: () => _waitUntilSubtitleTracksReady(player)',
      ),
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
