import 'package:flutter_test/flutter_test.dart';
import 'video_hibiki_page_source_corpus.dart';

/// 源码守卫：剧集列表走 push-aside 侧栏（把画面挤窄到左侧、与字幕列表风格统一），
/// 而非 `showModalBottomSheet`（底部弹层）（TODO-638）。
///
/// 用户报「视频的剧集列表弄成侧边栏或者什么的，和其他的显示效果差太多了」。此前剧集
/// 列表是底部弹层，与字幕列表（push-aside）/ 设置·倍速（overlay）风格不一致。改成与
/// 字幕列表同款 push-aside 侧栏（独立 [_episodeListVisible] 槽，与字幕列表互斥）。
///
/// media_kit 在 headless test 跑不起真视频 widget，故断言源码层的可见性路由与结构
/// （与 video_subtitle_list_push_aside_guard_test 同范式）。
void main() {
  late String src;
  setUpAll(() {
    src = readVideoHibikiSource();
  });

  test('剧集列表不再用 showModalBottomSheet（已改 push-aside 侧栏）', () {
    final int start = src.indexOf('void _showEpisodeList() {');
    expect(start, greaterThan(-1), reason: '应保留 _showEpisodeList 作为控制条入口');
    final int end = src.indexOf('\n  }', start);
    final String body = src.substring(start, end);
    expect(
      body.contains('showModalBottomSheet'),
      isFalse,
      reason: '剧集列表入口不应再用 showModalBottomSheet（已改 push-aside）',
    );
    expect(
      body.contains('_toggleEpisodeList()'),
      isTrue,
      reason: '_showEpisodeList 应翻转 push-aside 侧栏（_toggleEpisodeList）',
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

  test('_toggleEpisodeList 驱动 _episodeListVisible（push-aside），不走 overlay', () {
    final int start = src.indexOf('void _toggleEpisodeList() {');
    expect(start, greaterThan(-1), reason: '应有 _toggleEpisodeList 方法');
    final int end = src.indexOf('\n  }', start);
    final String body = src.substring(start, end);
    expect(
      body.contains('_episodeListVisible.value'),
      isTrue,
      reason: '应翻转 push-aside 可见性 _episodeListVisible',
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
      reason: '开 push-aside 剧集列表前应关掉字幕列表（同一右栏槽，互斥）',
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

  test('开任何浮层都关掉 push-aside 剧集列表（与字幕列表同处右栏）', () {
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
      reason: '开任何浮层都应关掉 push-aside 剧集列表',
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
          reason: '关闭应隐藏 push-aside 列表');
      expect(body.contains('_pokeControlsVisible()'), isTrue,
          reason: '关闭应唤回控制条');
      expect(body.contains('_refocusVideo()'), isTrue,
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
      expect(
        src.contains('if (_episodeListVisible.value) {\n            '
            '_closeEpisodeList();'),
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

  test('push-aside 布局渲染剧集面板列（_episodeSidePanel），用 VideoEpisodePanel', () {
    final int start = src.indexOf('Widget _videoWithSubtitlePanel(');
    expect(start, greaterThan(-1),
        reason: 'should have push-aside layout _videoWithSubtitlePanel');
    // 找到该方法到下一个 `\n  Widget ` 之间的体（含 _episodeSidePanel 调用）。
    final int rowIdx = src.indexOf('children: <Widget>[', start);
    final int rowEnd = src.indexOf('],', rowIdx);
    final String rowBody = src.substring(rowIdx, rowEnd);
    expect(
      rowBody.contains('_episodeSidePanel('),
      isTrue,
      reason: 'push-aside Row 应渲染剧集面板列 _episodeSidePanel',
    );
    expect(
      src.contains('child: VideoEpisodePanel('),
      isTrue,
      reason: '剧集面板列应渲染 VideoEpisodePanel widget',
    );
  });

  test('剧集列表 push-aside 也门控控制条 / rail 可见性（与字幕列表一致）', () {
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
