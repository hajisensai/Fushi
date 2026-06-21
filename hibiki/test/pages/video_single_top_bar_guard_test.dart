import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_control_customization.dart';

import 'video_hibiki_page_source_corpus.dart';

/// 源码守卫：视频播放页只保留**一条**顶栏（BUG-102）。
///
/// 根因：[_buildScaffold] 既给 Scaffold 配了 `appBar: AppBar(...)`，media_kit 的
/// controls 又自带「视频内顶栏」（topButtonBar）——两条顶栏内容重复、互相挤占，对
/// 用户毫无意义。修复是删掉 Scaffold AppBar，把返回/标题/剧集导航并入视频内顶栏，
/// 与播放控制一起随鼠标/触摸显隐。
///
/// 静态扫描守卫：按平台分流的真实 controls 渲染在 widget 测试里依赖 host 平台、
/// 难稳定复现移动/全屏分支（与 [video_mobile_controls_static_test] 同理）。
void main() {
  // TODO-590 batch11：两套 controls 主题已搬到 controls_theme.part.dart，改读合并语料
  // （主壳在前 + 全部 part 追加，端点保序）；顶栏 slot/title 的调用现落在 part 末段。
  late String src;
  setUpAll(() {
    src = readVideoHibikiSource();
  });

  test('Scaffold 不再配 AppBar（删掉外层顶栏）', () {
    expect(
      src.contains('appBar: AppBar('),
      isFalse,
      reason: '播放页不应再有 Scaffold AppBar，否则与视频内顶栏重复成两条顶栏',
    );
  });

  test('返回按钮进入视频内顶栏（桌面+移动两套主题各一）', () {
    // 删了 AppBar 自带的返回箭头后，返回必须改由视频内顶栏提供，且全屏可达。
    expect(
      RegExp(r'_topBarSlotGroup\(\s*VideoControlSlot\.topLeft')
          .allMatches(src)
          .length,
      greaterThanOrEqualTo(2),
      reason: '桌面与移动两套 controls 主题的顶栏都应渲染 topLeft slot',
    );
    expect(
        VideoControlLayout.currentChrome
            .itemsIn(VideoControlSlot.topLeft)
            .contains(VideoControlItem.back),
        isTrue,
        reason: '默认 topLeft slot 应承载返回按钮');
    expect(src.contains('case VideoControlItem.back:'), isTrue,
        reason: '返回按钮应继续接入 item dispatcher');
    expect(src.contains('_handleBackOrExit()'), isTrue,
        reason: 'topLeft 返回按钮应走视频退出 / 返回处理器');
  });

  test('标题进入视频内顶栏（响应式，全屏可刷新）', () {
    // 顶栏左侧显示书名/集名（原 AppBar 的 title 迁移到这里）。标题改用
    // ValueListenableBuilder 监听 _titleNotifier，全屏独立路由不随页面 setState 重建
    // 时也能刷新（BUG-120）；桌面 + 移动两套主题各一处。
    expect(
      '_topBarTitle()'.allMatches(src).length,
      greaterThanOrEqualTo(2),
      reason: '桌面与移动顶栏都应调用同一标题 helper（内部监听 _titleNotifier）',
    );
    expect(src.contains('valueListenable: _titleNotifier'), isTrue,
        reason: '标题 helper 内部仍应监听 _titleNotifier（BUG-120）');
  });

  test('标题用 Flexible(loose) 让宽给按钮，不用 Expanded 抢固定 1/3（TODO-642）', () {
    // 根因：_topBarTitle() 曾用 Expanded（= Flexible(FlexFit.tight)），强迫标题填满
    // 它分到的那段顶栏宽，把左右按钮组挤进窄横向滚动区（右上角按钮被裁 / 要横滑）。
    // 修复改成 Flexible(fit: FlexFit.loose)：标题只占自身需要的宽、剩余空间优先让给
    // 按钮组；标题已有 maxLines:1 + ellipsis，窄窗优雅截断。本守卫钉住该让位语义。
    final int titleStart = src.indexOf('Widget _topBarTitle()');
    expect(titleStart, greaterThanOrEqualTo(0),
        reason: '应存在 _topBarTitle() helper');
    final int titleEnd = src.indexOf('Widget _topBarInlineTitle(', titleStart);
    expect(titleEnd, greaterThan(titleStart),
        reason: '_topBarTitle() 方法体应正常闭合在 _topBarInlineTitle 之前');
    final String titleBody = src.substring(titleStart, titleEnd);
    expect(titleBody.contains('fit: FlexFit.loose'), isTrue,
        reason: 'TODO-642：标题须用 Flexible(fit: FlexFit.loose) 把宽让给按钮');
    expect(titleBody.contains('return Expanded('), isFalse,
        reason: 'TODO-642：标题不能再用 Expanded（FlexFit.tight 会抢固定 1/3 顶栏宽）');
    // 标题截断兜底仍在（窄窗让位后靠 ellipsis 优雅收尾）。
    final int textStart = src.indexOf('Widget _topBarTitleText(');
    expect(textStart, greaterThanOrEqualTo(0));
    final int textEnd =
        src.indexOf('Widget _buildBottomSlotButton(', textStart);
    expect(textEnd, greaterThan(textStart));
    final String textBody = src.substring(textStart, textEnd);
    expect(textBody.contains('maxLines: 1'), isTrue, reason: '标题单行');
    expect(textBody.contains('overflow: TextOverflow.ellipsis'), isTrue,
        reason: '标题溢出省略号');
  });

  test('标题使用稳定 helper，不靠右侧空槽占位维持位置（TODO-491）', () {
    expect(src.contains('Widget _topBarTitle('), isTrue,
        reason: '标题应集中到 helper，桌面/移动共用同一稳定布局');
    expect('_topBarTitle()'.allMatches(src).length, greaterThanOrEqualTo(2),
        reason: '桌面与移动顶栏都应使用同一标题 helper');

    final int groupStart = src.indexOf('Widget _topBarSlotGroup(');
    expect(groupStart, greaterThanOrEqualTo(0));
    final int groupEnd =
        src.indexOf('String get _clipExportTooltip', groupStart);
    expect(groupEnd, greaterThan(groupStart));
    final String group = src.substring(groupStart, groupEnd);
    expect(group.contains('if (items.isEmpty) return const SizedBox.shrink();'),
        isTrue,
        reason: '清空 topRight 时不能留下右侧空白占位挤歪标题');
  });
}
