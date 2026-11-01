import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_page_scripts.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

/// 页内查找的执行端（测试注入；生产对 [WebBrowserTab.controller] 跑页内脚本）。
typedef WebBrowserFindRunner = Future<Object?> Function(String script);

/// 页内查找条：输入框、`x/y` 计数、上一个 / 下一个、关闭。壳在
/// [WebBrowserTab.findOpen] 时摆出来（通常贴在工具栏位置）。
///
/// 五端统一走页内脚本（[kWebBrowserFindInstallScript]，CSS Custom Highlight 标出全部
/// 结果、当前一处另色）：Windows 的 WebView2 fork 没有原生查找接口。Enter 下一个，
/// Shift+Enter 上一个，Esc 关闭。
class WebBrowserFindBar extends StatefulWidget {
  const WebBrowserFindBar({required this.tab, this.runner, super.key});

  final WebBrowserTab tab;

  @visibleForTesting
  final WebBrowserFindRunner? runner;

  @override
  State<WebBrowserFindBar> createState() => WebBrowserFindBarState();
}

/// 壳经 `GlobalKey` 调 [step] / [focusQuery]：F3 / Ctrl+G 查找下一处、查找条已开时
/// 再按 Ctrl+F 回到输入框（与桌面浏览器一致）。
class WebBrowserFindBarState extends State<WebBrowserFindBar>
    with SingleTickerProviderStateMixin {
  final TextEditingController _query = TextEditingController();
  final FocusNode _focus = FocusNode(debugLabel: 'web-browser-find');
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: FushiMotion.medium,
  );
  WebBrowserFindResult _result = (count: 0, current: 0);

  /// 只认最近一次请求的结果（快速打字时旧结果晚到）。
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _enter.duration = fushiMotionDuration(context, FushiMotion.medium);
    if (!_enter.isAnimating && _enter.value == 0) unawaited(_enter.forward());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    unawaited(_run(kWebBrowserFindClearScript));
    _query.dispose();
    _focus.dispose();
    _enter.dispose();
    super.dispose();
  }

  Future<Object?> _run(String script) async {
    final WebBrowserFindRunner? runner = widget.runner;
    if (runner != null) return runner(script);
    final InAppWebViewController? controller = widget.tab.controller;
    if (controller == null) return null;
    try {
      return await controller.evaluateJavascript(source: script);
    } on Object {
      return null;
    }
  }

  Future<void> _apply(String script) async {
    final int generation = ++_generation;
    final WebBrowserFindResult result = parseWebBrowserFindResult(
      await _run(script),
    );
    if (!mounted || generation != _generation) return;
    setState(() => _result = result);
  }

  void _onChanged(String query) {
    if (query.isEmpty) {
      unawaited(_apply(kWebBrowserFindClearScript));
      return;
    }
    unawaited(_apply(webBrowserFindRunScript(query)));
  }

  void _step({required bool forward}) {
    if (_query.text.isEmpty) return;
    unawaited(_apply(webBrowserFindStepScript(forward: forward)));
  }

  /// 跳到下一处 / 上一处结果（查找词为空时不动）。
  void step({required bool forward}) => _step(forward: forward);

  /// 把焦点放回查找输入框并全选已有查找词。
  void focusQuery() {
    _focus.requestFocus();
    _query.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _query.text.length,
    );
  }

  void _close() => widget.tab.update(findOpen: false);

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool hasQuery = _query.text.isNotEmpty;
    final String count = !hasQuery
        ? ''
        : _result.count == 0
        ? t.web_browser_find_none
        : '${_result.current}/${_result.count}';
    final Animation<double> curved = CurvedAnimation(
      parent: _enter,
      curve: Easing.emphasizedDecelerate,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.25),
          end: Offset.zero,
        ).animate(curved),
        child: Focus(
          onKeyEvent: _onKey,
          child: Row(
            key: const ValueKey<String>('web-browser-find-bar'),
            children: <Widget>[
              Expanded(
                child: FushiSearchField(
                  fieldKey: const ValueKey<String>('web-browser-find-field'),
                  controller: _query,
                  focusNode: _focus,
                  hintText: t.web_browser_find_hint,
                  onChanged: (String value) {
                    setState(() {});
                    _onChanged(value);
                  },
                  onClear: () {
                    _query.clear();
                    setState(() {});
                    _onChanged('');
                  },
                  onSubmitted: (String _) {
                    _step(forward: !HardwareKeyboard.instance.isShiftPressed);
                    _focus.requestFocus();
                  },
                  trailing: <Widget>[
                    if (count.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          count,
                          key: const ValueKey<String>('web-browser-find-count'),
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontFeatures: const <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              FushiIconButton(
                key: const ValueKey<String>('web-browser-find-previous'),
                tooltip: t.web_browser_find_previous,
                icon: FushiIcons.expandLess,
                onTap: _result.count > 0 ? () => _step(forward: false) : null,
              ),
              FushiIconButton(
                key: const ValueKey<String>('web-browser-find-next'),
                tooltip: t.web_browser_find_next,
                icon: FushiIcons.expandMore,
                onTap: _result.count > 0 ? () => _step(forward: true) : null,
              ),
              FushiIconButton(
                key: const ValueKey<String>('web-browser-find-close'),
                tooltip: t.web_browser_find_close,
                icon: FushiIcons.close,
                onTap: _close,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
