import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

void main() {
  // BUG-120: 全屏下切集黑屏 00:00 + 左上标题不刷新。根因 = media_kit 全屏是推到根
  // navigator 的独立路由，进入时快照捕获当时的 VideoController 实例与控制条主题（含
  // 标题字符串），页面 setState 不重建全屏路由。①换集每次 dispose+new VideoController
  // 让全屏路由绑在旧实例上 → 黑屏；②标题字符串固定进 theme 快照 → 不刷新。根因修=
  // 复用 Player/VideoController（player.open 换片）+ 标题走 ValueNotifier/ValueListenableBuilder。
  // 全屏黑屏与真实 libmpv 渲染 headless 不可复现，用源码守卫锁住关键接线防回归。
  final String controllerSource = File(
    'lib/src/media/video/video_player_controller.dart',
  ).readAsStringSync();
  // TODO-590 batch11：两套 controls 主题已搬到 controls_theme.part.dart，标题接线
  // （`_topBarTitle()` 的两处调用）随之搬出主壳，故改读合并语料；`_topBarTitle()`
  // 定义与 `_buildBottomSlotButton(` 端点仍在主壳（语料最前段），切片不受影响。
  final String pageSource = readVideoHibikiSource();

  test('load() reuses Player/VideoController across episodes (no recreate)',
      () {
    final String fn = _functionSource(
      controllerSource,
      '  Future<void> load({',
      '  Future<void> _loadEmbeddedSubtitleIfNeeded(',
    );
    // 复用：用 `_player ?? Player()`，仅 _player==null 时建 VideoController。
    expect(fn, contains('_player ?? Player()'),
        reason: '换集必须复用同一 Player，否则全屏路由绑旧实例黑屏（BUG-120）');
    expect(fn, contains('if (_player == null) {'),
        reason: 'VideoController 仅首次实例化，换集复用同一实例');

    // 不得在 load 内 dispose 旧 player 后重建 VideoController（旧的黑屏根因写法）。
    expect(fn.contains('await _player?.dispose()'), isFalse,
        reason: 'load() 内不应 dispose 旧 player（会让全屏路由的 VideoController 失效）');
    // VideoController 构造只应出现在 _player==null 守卫内，全文件至多一次。
    expect('VideoController('.allMatches(fn).length, lessThanOrEqualTo(1),
        reason: 'load() 内 VideoController 至多构造一次（仅首次）');
  });

  test('top bar title is reactive via ValueListenable (fullscreen-safe)', () {
    expect(pageSource, contains('ValueNotifier<String?> _titleNotifier'),
        reason: '标题需 ValueNotifier 承载，全屏路由才能监听刷新（BUG-120）');
    expect(pageSource, contains('_titleNotifier.value = title'),
        reason: '_applyLoad 必须把新标题推给 notifier');
    expect(pageSource, contains('_titleNotifier.dispose()'),
        reason: 'dispose 必须释放 _titleNotifier');
    // 两套控制条主题（桌面 + 移动）都应接入响应式标题 helper，不再裸 Text(_title)。
    // TODO-491 把两处 ValueListenableBuilder 提炼为同一个稳定布局 helper，避免右侧
    // 自定义 slot 清空时靠空白占位维持标题位置。
    expect(
        '_topBarTitle()'.allMatches(pageSource).length, greaterThanOrEqualTo(2),
        reason: '桌面与移动两套控制条主题的标题都要接入响应式 helper');
    final String titleHelper = _functionSource(
      pageSource,
      '  Widget _topBarTitle() {',
      '  Widget _buildBottomSlotButton(',
    );
    expect(titleHelper, contains('valueListenable: _titleNotifier'),
        reason: '标题 helper 必须用 ValueListenableBuilder 监听 _titleNotifier');
    expect(titleHelper, contains('AlignmentDirectional.centerStart'),
        reason: '标题 helper 应固定标题起点，避免 topRight 空槽挤歪标题');
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
