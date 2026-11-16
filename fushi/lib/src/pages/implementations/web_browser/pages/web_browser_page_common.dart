import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';

/// 数据页（历史 / 书签 / 下载）打开网址的回调：[newTab] 为 true 时在新标签页打开。
/// 页面调用后会自行 pop 回浏览器（[newTab] 为 false 时）。
typedef WebBrowserPageOpenCallback = void Function(Uri url, {bool newTab});

/// 「清除历史 / 清除浏览数据」的时间范围。
enum WebBrowserClearRange {
  lastHour(Duration(hours: 1)),
  lastDay(Duration(hours: 24)),
  lastWeek(Duration(days: 7)),
  lastMonth(Duration(days: 28)),
  allTime(null);

  const WebBrowserClearRange(this.span);

  /// null = 全部时间。
  final Duration? span;

  /// 交给 store 的 `since`：null = 全部。
  DateTime? sinceFrom(DateTime now) {
    final Duration? s = span;
    return s == null ? null : now.subtract(s);
  }

  String get label => switch (this) {
    WebBrowserClearRange.lastHour => t.web_browser_range_last_hour,
    WebBrowserClearRange.lastDay => t.web_browser_range_last_day,
    WebBrowserClearRange.lastWeek => t.web_browser_range_last_week,
    WebBrowserClearRange.lastMonth => t.web_browser_range_last_month,
    WebBrowserClearRange.allTime => t.web_browser_range_all,
  };
}

/// 显示一条普通提示。
void showWebBrowserPageSnack(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(FushiSnackBar(content: Text(message)));
}

/// 网址的显示文案：去掉协议与末尾斜杠。
String webBrowserDisplayUrl(Uri url) {
  String text = url.toString();
  text = text.replaceFirst(RegExp(r'^https?://'), '');
  if (text.endsWith('/')) text = text.substring(0, text.length - 1);
  return text;
}

/// 列表页的标准外框：正文消费页头让位（`MediaQuery.paddingOf(context).top`）与
/// 底部安全区，错峰进场窗口随 [replayKey] 重开。内部用 [Builder] 取
/// [FushiPageScaffold] 注入给正文的 MediaQuery（调用方传进来的 context 可能在
/// 脚手架之外，拿不到页头让位）。
Widget webBrowserPageListView({
  required Object? replayKey,
  required List<Widget> children,
  Key? key,
}) => FushiEntranceScope(
  replayKey: replayKey,
  child: Builder(
    builder: (BuildContext context) => ListView(
      key: key,
      padding: EdgeInsets.only(
        top: 8 + MediaQuery.paddingOf(context).top,
        bottom: 24 + bottomSafeInsetOf(context),
      ),
      children: children,
    ),
  ),
);
