import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/features/open_in_fushi/web_page_content.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';

/// 上下文按钮在工具栏上的优先级（工具栏放不下时按它收进「⋯」；导航类内置动作占 90+）。
const int kWebOpenInFushiToolbarPriority = 80;

/// 收在「⋯」里时的优先级。
const int kWebOpenInFushiMenuPriority = 40;

/// 「交给 Fushi」的统一入口：视频「用 Fushi 播放」、漫画 / 小说「用 Fushi 阅读」三个功能都经
/// 这一处造动作——同一套 id、图标、文案与摆放，用户在浏览器里只认一个按钮。
///
/// [primary]：页面内容就是 [kind] 这一类（[WebPageContentFeature] 探出来的，或地址就能断定的
/// 观看页）→ 放工具栏、文案不带类别；否则收进「⋯」，文案带上类别（探针认错时用户仍够得到，
/// 也分得清「作为漫画」还是「作为小说」）。[busy] 时动作显示为进行中且不可再点。
WebBrowserAction webOpenInFushiAction({
  required WebPageContentKind kind,
  required bool primary,
  required VoidCallback? onPressed,
  bool busy = false,
}) => WebBrowserAction(
  id: webOpenInFushiActionId(kind),
  icon: switch (kind) {
    WebPageContentKind.video => FushiIcons.playCircle,
    WebPageContentKind.comic => FushiIcons.manga,
    WebPageContentKind.novel => FushiIcons.books,
  },
  label: webOpenInFushiLabel(kind, primary: primary),
  placement: primary
      ? WebBrowserActionPlacement.toolbar
      : WebBrowserActionPlacement.menu,
  priority: primary
      ? kWebOpenInFushiToolbarPriority
      : kWebOpenInFushiMenuPriority,
  selected: busy,
  onPressed: busy ? null : onPressed,
);

/// 动作 id：`open_in_fushi.<kind>`。
String webOpenInFushiActionId(WebPageContentKind kind) =>
    'open_in_fushi.${kind.name}';

/// 动作文案：工具栏上只说「播放 / 阅读」，「⋯」里带上类别。
String webOpenInFushiLabel(WebPageContentKind kind, {required bool primary}) =>
    switch (kind) {
      WebPageContentKind.video => t.web_browser_play_in_fushi,
      WebPageContentKind.comic =>
        primary
            ? t.web_browser_read_in_fushi
            : t.web_browser_read_in_fushi_as_comic,
      WebPageContentKind.novel =>
        primary
            ? t.web_browser_read_in_fushi
            : t.web_browser_read_in_fushi_as_novel,
    };
