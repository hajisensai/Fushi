import 'package:flutter_test/flutter_test.dart';
import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 源码守卫：字幕跳转列表走 push-aside（把画面挤窄到左侧），而非 overlay 浮层遮挡
/// （TODO-314 / BUG-256）。
///
/// 根因：此前 `_toggleSubtitleJumpList` 误经 `_showVideoSidePanel(subtitleList)` 进 overlay
/// side-panel 系统，且 `_showVideoSidePanel` 无条件把 `_subtitleListVisible` 置 false →
/// 真正的 push-aside 布局 `_videoWithSubtitlePanel`（`Row[Expanded(video), 面板列]`）成死
/// 代码，列表改由 overlay `Align centerRight` 浮在画面上遮挡。
///
/// 修复：`_toggleSubtitleJumpList` 改驱动 `_subtitleListVisible`（push-aside）；从
/// `_VideoSidePanelKind` 删除 subtitleList 枚举值。
///
/// BUG-1501 之后本函数还多了一层**选集横轨**的点外关闭 barrier（由 `episodeVisible`
/// 单独门控，与字幕列表互斥）。它与下面 TODO-637 的禁令不冲突：禁的是「跟着字幕列表
/// 挂的 barrier」，不是 `HitTestBehavior.opaque` 这个词本身。
///
/// TODO-637：字幕列表改回「带 × 的非阻塞侧栏」——画面区**不再叠** opaque barrier
/// （BUG-256 的「点画面关列表」层罩在画面字幕查词手势上致 TODO-636 画面查不了词），
/// 关闭统一走面板头部 × / Esc / 控制条字幕按钮（各含挖词选择清理）。
///
/// media_kit 在 headless test 跑不起真视频 widget，故断言源码层的可见性路由与结构。
void main() {
  late String src;
  setUpAll(() {
    src = readVideoFushiSource();
  });

  test('字幕列表枚举已从 overlay side-panel 系统移除（subtitleList 不再是 _VideoSidePanelKind）',
      () {
    final int enumStart = src.indexOf('enum _VideoSidePanelKind {');
    expect(enumStart, greaterThan(-1), reason: '应有 _VideoSidePanelKind 枚举');
    final int enumEnd = src.indexOf('}', enumStart);
    final String enumBody = src.substring(enumStart, enumEnd);
    expect(
      enumBody.contains('subtitleList'),
      isFalse,
      reason: 'subtitleList 已改 push-aside，不应再是 overlay 面板 kind',
    );
  });

  test('_toggleSubtitleJumpList 驱动 _subtitleListVisible（push-aside），不走 overlay',
      () {
    final int start = src.indexOf('void _toggleSubtitleJumpList() {');
    expect(start, greaterThan(-1), reason: '应有 _toggleSubtitleJumpList 方法');
    final int end = src.indexOf('\n  }', start);
    final String body = src.substring(start, end);
    expect(
      body.contains('_subtitleListVisible.value'),
      isTrue,
      reason: '应翻转 push-aside 可见性 _subtitleListVisible',
    );
    expect(
      body.contains('_showVideoSidePanel(_VideoSidePanelKind.subtitleList'),
      isFalse,
      reason: '不应再经 overlay side-panel 系统开字幕列表',
    );
  });

  test('字幕列表与浮层互斥：开 push-aside 列表先关浮层，开浮层关 push-aside 列表', () {
    // _toggleSubtitleJumpList 开列表前关浮层。
    final int toggleStart = src.indexOf('void _toggleSubtitleJumpList() {');
    final int toggleEnd = src.indexOf('\n  }', toggleStart);
    final String toggleBody = src.substring(toggleStart, toggleEnd);
    expect(
      toggleBody.contains('_hideVideoSidePanel()'),
      isTrue,
      reason: '开 push-aside 字幕列表前应关掉打开的浮层',
    );
    // _showVideoSidePanel 开浮层时关 push-aside 列表。
    final int showStart = src.indexOf('void _showVideoSidePanel(');
    expect(showStart, greaterThan(-1));
    final int showEnd =
        src.indexOf('\n  void _hideVideoSidePanel()', showStart);
    expect(showEnd, greaterThan(showStart));
    final String showBody = src.substring(showStart, showEnd);
    expect(
      showBody.contains('_subtitleListVisible.value = false'),
      isTrue,
      reason: '开任何浮层都应关掉 push-aside 字幕列表',
    );
  });

  test(
      'TODO-637 non-blocking sidebar: video area has NO opaque barrier '
      '(restores picture-subtitle lookup, TODO-636)', () {
    // 边界由 [methodBody] 做括号配对，不再用 `indexOf('\n  }')` 猜——那个写法把
    // 「函数体到哪结束」交给缩进巧合，函数里多一层 2 空格闭合就整段截错。
    final String body = methodBody(src, 'Widget _videoWithSubtitlePanel(');
    final String code = maskComments(body);
    // TODO-637 的契约是「**字幕列表** push-aside 时画面区不叠 barrier」，不是
    // 「本函数里不许出现 opaque 这个词」。BUG-1501 之后同一个 Stack 还要负责选集
    // 横轨的「点画面关横轨」barrier，它由 `episodeVisible` 单独门控，与字幕列表
    // 互斥（横轨出现时字幕侧栏宽度必为 0）。旧判据整段扫函数体，横轨 barrier 一
    // 落地就把它判红，而 TODO-636 真正怕的那层（无门控、跟着字幕列表一起挂的
    // barrier）它反而分不出来——判据的粒度错了，不是实现错了。
    //
    // 改成按**状态归属**切：
    //  ① 字幕列表那条 Row 所在区间（= `if (episodeVisible)` 之前）绝不许有 barrier；
    //  ② 全函数只允许存在那**一个** barrier，且必须是选集那一个（按 key 认）。
    // 两条都要：只有①的话，在横轨分支外再挂一层无门控 barrier 仍能过。
    final int episodeGate = code.indexOf('if (episodeVisible)');
    expect(episodeGate, greaterThan(-1),
        reason: '选集横轨 barrier 必须由 episodeVisible 门控（BUG-1501）；'
            '门控没了就是画面区常驻一层罩子');
    expect(
      code.substring(0, episodeGate).contains('HitTestBehavior.opaque'),
      isFalse,
      reason: 'video area must not have an opaque barrier '
          '(it would eat the picture-subtitle lookup gesture, TODO-636)',
    );
    expect(
      'HitTestBehavior.opaque'.allMatches(code).length,
      1,
      reason: '本函数只允许存在选集横轨那一个 barrier；多出来的一定罩在画面上',
    );
    expect(
      code.contains("'video-episode-dismiss-barrier'"),
      isTrue,
      reason: '那唯一一个 barrier 必须就是选集横轨的点外关闭面（BUG-1501）',
    );
    // Close is carried by the header X / Esc / subtitle button; this layout
    // function no longer closes the list directly and no longer passes a lock.
    expect(
      body.contains('_subtitleJumpSidePanel(controller, visible)'),
      isTrue,
      reason: 'layout should delegate the panel column to '
          '_subtitleJumpSidePanel (no lock arg)',
    );
  });

  test('删除了 overlay 版 _buildSubtitleListSidePanel（已无 overlay 路径）', () {
    expect(
      src.contains('Widget _buildSubtitleListSidePanel('),
      isFalse,
      reason: 'overlay 版字幕列表面板构造器应随 push-aside 改造删除',
    );
  });

  // TODO-637 一致性守卫：三条关闭路径（面板头部 × / Esc / 控制条字幕按钮）必须
  // 语义等价——都经单一真相源 _closeSubtitleJumpList，避免「关闭副作用各写一份」再分叉
  // （此前 × 的 onClose 只隐藏列表，漏 _pokeControlsVisible / _refocusVideo，致点 ×
  // 后控制条不被唤回、焦点不归还视频，键盘 / 手柄后续失焦）。
  group(
      'TODO-637 close-path parity: three close paths funnel through '
      '_closeSubtitleJumpList', () {
    test(
        '_closeSubtitleJumpList 含全部三项关闭副作用'
        '（隐藏列表 + 唤回控制条 + 归还焦点）', () {
      final int start = src.indexOf('void _closeSubtitleJumpList() {');
      expect(start, greaterThan(-1), reason: '应有单一真相源 _closeSubtitleJumpList');
      final int end = src.indexOf('\n  }', start);
      final String body = src.substring(start, end);
      expect(body.contains('_subtitleListVisible.value = false'), isTrue,
          reason: '关闭应隐藏 push-aside 列表');
      expect(body.contains('_pokeControlsVisible()'), isTrue,
          reason: '关闭应唤回控制条（× 路径此前漏此项）');
      expect(
          body.contains(
              '_focusOwnership.reclaim(FocusReclaimCause.overlayClosed)'),
          isTrue,
          reason: '关闭应把焦点归还视频（× 路径此前漏此项，否则键盘 / 手柄失焦）');
    });

    test('面板头部 × 的 onClose 经 _closeSubtitleJumpList（不再各写一份副作用）', () {
      expect(
        src.contains('onClose: _closeSubtitleJumpList'),
        isTrue,
        reason: 'VideoSubtitleJumpPanel 的 onClose 应直接复用 _closeSubtitleJumpList，'
            '与 Esc / 控制条字幕按钮关闭路径等价',
      );
    });

    test(
        '_toggleSubtitleJumpList 的关闭分支经 _closeSubtitleJumpList'
        '（Esc / 控制条字幕按钮共用此入口）', () {
      final int start = src.indexOf('void _toggleSubtitleJumpList() {');
      expect(start, greaterThan(-1));
      final int end = src.indexOf('\n  }', start);
      final String body = src.substring(start, end);
      // 关闭分支（else）应调单一真相源，而非内联重复写四项副作用。
      final int elseIdx = body.indexOf('} else {');
      expect(elseIdx, greaterThan(-1), reason: '应有关闭分支 else');
      final String elseBody = body.substring(elseIdx);
      expect(
        elseBody.contains('_closeSubtitleJumpList()'),
        isTrue,
        reason: 'toggle 的关闭分支应复用 _closeSubtitleJumpList，'
            'Esc（line ~3427）与控制条字幕按钮经此分支自动等价',
      );
    });
  });
}
