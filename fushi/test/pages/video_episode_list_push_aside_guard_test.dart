import 'package:flutter_test/flutter_test.dart';
import 'video_fushi_page_source_corpus.dart';

/// 源码守卫：剧集列表走视频底部的非模态横向轨道，而非
/// `showModalBottomSheet` 或会挤窄画面的右侧栏。
///
/// 字幕列表仍是 push-aside；剧集轨道覆盖在视频底部，以画面本身作沉浸式背景。
/// 两者继续共用 [_episodeListVisible] / [_subtitleListVisible] 互斥状态。
///
/// media_kit 在 headless test 跑不起真视频 widget，故断言源码层的可见性路由与结构
/// （与 video_subtitle_list_push_aside_guard_test 同范式）。
void main() {
  late String src;
  setUpAll(() {
    src = readVideoFushiSource();
  });

  test('剧集列表不再用 showModalBottomSheet（已改底部横向轨道）', () {
    final int start = src.indexOf('void _showEpisodeList() {');
    expect(start, greaterThan(-1), reason: '应保留 _showEpisodeList 作为控制条入口');
    final int end = src.indexOf('\n  }', start);
    final String body = src.substring(start, end);
    expect(
      body.contains('showModalBottomSheet'),
      isFalse,
      reason: '剧集列表入口不应再用 showModalBottomSheet（已改横向轨道）',
    );
    expect(
      body.contains('_toggleEpisodeList()'),
      isTrue,
      reason: '_showEpisodeList 应翻转非模态剧集轨道（_toggleEpisodeList）',
    );
  });

  test('整个视频页不再有 showModalBottomSheet 调用（剧集列表是最后一个底部弹层）', () {
    // 只断言「调用」（`showModalBottomSheet<` / `showModalBottomSheet(`），不误伤
    // 文档注释里反引号引用的 `showModalBottomSheet`（说明改造历史）。
    expect(
      src.contains('showModalBottomSheet<') ||
          src.contains('showModalBottomSheet('),
      isFalse,
      reason: '剧集列表改 push-aside 后视频页应无 showModalBottomSheet 调用',
    );
  });

  test('_toggleEpisodeList 驱动 _episodeListVisible，不走 modal route', () {
    final int start = src.indexOf('void _toggleEpisodeList() {');
    expect(start, greaterThan(-1), reason: '应有 _toggleEpisodeList 方法');
    final int end = src.indexOf('\n  }', start);
    final String body = src.substring(start, end);
    expect(
      body.contains('_episodeListVisible.value'),
      isTrue,
      reason: '应翻转剧集轨道可见性 _episodeListVisible',
    );
  });

  test('剧集列表与字幕列表互斥：开剧集列表先关字幕列表，开字幕列表先关剧集列表', () {
    // _toggleEpisodeList 开列表前关字幕列表。
    final int epStart = src.indexOf('void _toggleEpisodeList() {');
    final int epEnd = src.indexOf('\n  }', epStart);
    final String epBody = src.substring(epStart, epEnd);
    expect(
      epBody.contains('_closeSubtitleJumpList()'),
      isTrue,
      reason: '开剧集轨道前应关掉字幕列表（互斥）',
    );
    expect(
      epBody.contains('_hideVideoSidePanel()'),
      isTrue,
      reason: '开 push-aside 剧集列表前应关掉任何打开的浮层',
    );
    // _toggleSubtitleJumpList 开列表前关剧集列表。
    final int subStart = src.indexOf('void _toggleSubtitleJumpList() {');
    final int subEnd = src.indexOf('\n  }', subStart);
    final String subBody = src.substring(subStart, subEnd);
    expect(
      subBody.contains('_closeEpisodeList()'),
      isTrue,
      reason: '开 push-aside 字幕列表前应关掉剧集列表（互斥）',
    );
  });

  test('开任何浮层都关掉剧集轨道', () {
    // _showVideoSidePanel 开浮层时关剧集列表。
    final int showStart = src.indexOf('void _showVideoSidePanel(');
    expect(showStart, greaterThan(-1));
    final int showEnd =
        src.indexOf('\n  void _hideVideoSidePanel()', showStart);
    expect(showEnd, greaterThan(showStart));
    final String showBody = src.substring(showStart, showEnd);
    expect(
      showBody.contains('_episodeListVisible.value = false'),
      isTrue,
      reason: '开任何浮层都应关掉剧集轨道',
    );
  });

  // 三条关闭路径（面板头部 × / Esc / 控制条剧集按钮）必须语义等价——都经单一真相源
  // _closeEpisodeList，避免「关闭副作用各写一份」再分叉（与 TODO-637 字幕列表同纪律）。
  group(
      'TODO-638 close-path parity: three close paths funnel through '
      '_closeEpisodeList', () {
    test(
        '_closeEpisodeList 含全部三项关闭副作用'
        '（隐藏列表 + 唤回控制条 + 归还焦点）', () {
      final int start = src.indexOf('void _closeEpisodeList() {');
      expect(start, greaterThan(-1), reason: '应有单一真相源 _closeEpisodeList');
      final int end = src.indexOf('\n  }', start);
      final String body = src.substring(start, end);
      expect(body.contains('_episodeListVisible.value = false'), isTrue,
          reason: '关闭应隐藏剧集轨道');
      expect(body.contains('_pokeControlsVisible()'), isTrue,
          reason: '关闭应唤回控制条');
      expect(
          body.contains(
              '_focusOwnership.reclaim(FocusReclaimCause.overlayClosed)'),
          isTrue,
          reason: '关闭应把焦点归还视频（否则键盘 / 手柄失焦）');
    });

    test('面板头部 × 的 onClose 经 _closeEpisodeList', () {
      expect(
        src.contains('onClose: _closeEpisodeList'),
        isTrue,
        reason: 'VideoEpisodePanel 的 onClose 应复用 _closeEpisodeList，与 Esc / '
            '控制条剧集按钮关闭路径等价',
      );
    });

    test('Esc 在剧集列表开着时先关它（经 _closeEpisodeList）', () {
      // 断言语义而非硬编码缩进：某个 `if (_episodeListVisible.value) {` 的紧邻下一
      // 语句是 `_closeEpisodeList();`（即 Esc 分支逐级退出）。用 \s* 容忍缩进/换行，
      // 避免 escape 处理器被重构成不同嵌套深度（如 TODO-1342 手柄映射）时假红。
      expect(
        RegExp(r'if \(_episodeListVisible\.value\) \{\s*_closeEpisodeList\(\);')
            .hasMatch(src),
        isTrue,
        reason: 'Esc 分支应在剧集列表开着时调 _closeEpisodeList 逐级退出',
      );
    });

    test('_toggleEpisodeList 的关闭分支经 _closeEpisodeList', () {
      final int start = src.indexOf('void _toggleEpisodeList() {');
      final int end = src.indexOf('\n  }', start);
      final String body = src.substring(start, end);
      final int elseIdx = body.indexOf('} else {');
      expect(elseIdx, greaterThan(-1), reason: '应有关闭分支 else');
      final String elseBody = body.substring(elseIdx);
      expect(
        elseBody.contains('_closeEpisodeList()'),
        isTrue,
        reason: 'toggle 的关闭分支应复用 _closeEpisodeList',
      );
    });
  });

  test('视频布局用 Stack 渲染底部剧集轨道，不把它放进 push-aside Row', () {
    final int start = src.indexOf('Widget _videoWithSubtitlePanel(');
    expect(start, greaterThan(-1),
        reason: 'should have push-aside layout _videoWithSubtitlePanel');
    final int end = src.indexOf('\n  Widget ', start + 1);
    final String body = src.substring(start, end);
    expect(
      body.contains('return Stack('),
      isTrue,
      reason: '视频与剧集轨道应叠在 Stack 中',
    );
    expect(
      body.contains('_episodeOverlayPanel(episodeVisible)'),
      isTrue,
      reason: 'Stack 应渲染底部 _episodeOverlayPanel',
    );
    final int barrier = body.indexOf("'video-episode-dismiss-barrier'");
    final int panel = body.indexOf('_episodeOverlayPanel(episodeVisible)');
    expect(barrier, greaterThan(-1), reason: '选集打开时应在视频区挂点外关闭 barrier');
    expect(panel, greaterThan(barrier),
        reason: '选集横轨必须绘制在 barrier 之上，保证卡片与 X 仍可点击');
    expect(body.contains('if (episodeVisible)'), isTrue,
        reason: '选集隐藏时 barrier 必须从树中移除，不能拦截普通视频点击');
    expect(body.contains('onTap: _closeEpisodeList'), isTrue,
        reason: '点击视频区应复用选集关闭的单一真相源');
    expect(
      body.contains('_episodeSidePanel('),
      isFalse,
      reason: '剧集列表不应再作为 Row 侧栏挤窄视频',
    );
    expect(
      src.contains('child: VideoEpisodePanel('),
      isTrue,
      reason: '剧集轨道应渲染 VideoEpisodePanel widget',
    );
  });

  test('BUG-1501：选集可见时页面 pointer-up 早返回，不触发播放器双击手势', () {
    final int start = src.indexOf('void _handleVideoPointerUp(');
    expect(start, greaterThan(-1));
    final int end = src.indexOf('\n  /// TODO-1058', start);
    expect(end, greaterThan(start));
    final String body = src.substring(start, end);
    final int episodeGuard = body.indexOf('if (_episodeListVisible.value)');
    final int doubleClick = body.indexOf('final DateTime now = DateTime.now()');
    expect(episodeGuard, greaterThan(-1));
    expect(doubleClick, greaterThan(episodeGuard),
        reason: '选集可见门控必须先于双击 / 暂停 / 全屏判定');
    expect(
      body.substring(episodeGuard, doubleClick),
      contains('return;'),
      reason: 'barrier 点击的 pointer-up 必须被消费，只留下 onTap 关闭选集',
    );
  });

  test('剧集面板封面统一走 resolveMediaCoverImage，兼容本地与互联成员', () {
    expect(src.contains('this.coverPath,'), isTrue,
        reason: '_PlaylistEpisodeRef 应承载本地封面路径');
    expect(src.contains('this.coverUrl,'), isTrue,
        reason: '_PlaylistEpisodeRef 应承载互联封面 URL');
    expect(src.contains('this.coverCacheKey,'), isTrue,
        reason: '_PlaylistEpisodeRef 应承载远端稳定缓存键');
    expect(src.contains('coverPath: er.coverPath'), isTrue,
        reason: '本地合集成员应把 video_books.coverPath 带进面板');
    expect(src.contains('coverUrl: m.coverUrl'), isTrue,
        reason: '互联合集成员应把 RemoteVideoInfo.coverUrl 带进面板');
    expect(src.contains('coverCacheKey: m.id'), isTrue,
        reason: '互联封面应使用 RemoteVideoInfo.id 作稳定缓存键');
    expect(src.contains('resolveMediaCoverImage('), isTrue,
        reason: '封面来源应统一走显示侧解析器，不在剧集面板手写来源分支');
    expect(src.contains('episodes: _episodePanelEntries()'), isTrue,
        reason: 'VideoEpisodePanel 应接收解析后的标题与封面条目');
  });

  test('剧集轨道也门控控制条 / rail 可见性（与字幕列表一致）', () {
    // _applyControlsVisibilityFromMediaKit 的 gated 应含 _episodeListVisible。
    final int start =
        src.indexOf('void _applyControlsVisibilityFromMediaKit() {');
    expect(start, greaterThan(-1));
    final int end = src.indexOf('\n  }', start);
    final String body = src.substring(start, end);
    expect(
      body.contains('_episodeListVisible.value'),
      isTrue,
      reason: '剧集列表开着时控制条应被门控（与字幕列表一致）',
    );
  });
}
