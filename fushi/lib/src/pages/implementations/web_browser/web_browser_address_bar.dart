import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/web_browser/web_browser_layout.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/web_browser_suggestions.dart';

/// 联想下拉弹出的方向：顶栏往下、底栏往上。
enum WebBrowserSuggestionsDirection { down, up }

/// 地址栏：平时显示「🔒 前缀（淡）域名（粗）其余（淡）☆」，点一下变成可编辑的
/// 搜索框（两套设计系统都走 [FushiSearchField]），输入时下拉联想（历史 + 书签 +
/// 搜索引擎在线联想，数据源 [WebBrowserSuggestionsController]），↑↓ 选、Enter 开。
class WebBrowserAddressBar extends StatefulWidget {
  const WebBrowserAddressBar({
    required this.url,
    required this.focusNode,
    required this.suggestions,
    required this.onSubmitted,
    required this.onOpenSuggestion,
    super.key,
    this.bookmarked = false,
    this.onToggleBookmark,
    this.onReload,
    this.incognito = false,
    this.direction = WebBrowserSuggestionsDirection.down,
  });

  /// 当前页地址；null = 新标签页（直接显示输入框提示）。
  final Uri? url;
  final FocusNode focusNode;
  final WebBrowserSuggestionsController suggestions;

  /// 回车：原样交给壳按搜索引擎解析。
  final ValueChanged<String> onSubmitted;
  final ValueChanged<WebBrowserSuggestion> onOpenSuggestion;
  final bool bookmarked;

  /// null = 不显示 ☆（新标签页 / 无痕）。
  final VoidCallback? onToggleBookmark;

  /// 非 null 时尾部带刷新（手机横屏 / 竖屏底栏，v3）。
  final VoidCallback? onReload;
  final bool incognito;
  final WebBrowserSuggestionsDirection direction;

  @override
  State<WebBrowserAddressBar> createState() => WebBrowserAddressBarState();
}

class WebBrowserAddressBarState extends State<WebBrowserAddressBar> {
  final TextEditingController _text = TextEditingController();
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();
  final GlobalKey _box = GlobalKey(debugLabel: 'web-browser-address-box');
  StreamSubscription<List<WebBrowserSuggestion>>? _sub;
  List<WebBrowserSuggestion> _items = const <WebBrowserSuggestion>[];
  int _highlight = -1;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocus);
    _sub = widget.suggestions.suggestions.listen(_onSuggestions);
    _editing = widget.focusNode.hasFocus;
  }

  @override
  void didUpdateWidget(WebBrowserAddressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.focusNode, widget.focusNode)) {
      oldWidget.focusNode.removeListener(_onFocus);
      widget.focusNode.addListener(_onFocus);
    }
    if (!identical(oldWidget.suggestions, widget.suggestions)) {
      unawaited(_sub?.cancel());
      _sub = widget.suggestions.suggestions.listen(_onSuggestions);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocus);
    unawaited(_sub?.cancel());
    _text.dispose();
    super.dispose();
  }

  void _onFocus() {
    final bool focused = widget.focusNode.hasFocus;
    if (focused == _editing) return;
    setState(() {
      _editing = focused;
      if (focused) {
        _text.text = widget.url?.toString() ?? '';
        _text.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _text.text.length,
        );
      } else {
        _items = const <WebBrowserSuggestion>[];
        _highlight = -1;
      }
    });
    if (!focused) {
      _portal.hide();
      unawaited(widget.suggestions.update(''));
    }
  }

  void _onSuggestions(List<WebBrowserSuggestion> items) {
    if (!mounted || !_editing) return;
    setState(() {
      _items = items;
      if (_highlight >= items.length) _highlight = -1;
    });
    if (items.isEmpty) {
      _portal.hide();
    } else {
      _portal.show();
    }
  }

  void beginEditing() {
    if (!_editing) {
      setState(() {
        _editing = true;
        _text.text = widget.url?.toString() ?? '';
        _text.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _text.text.length,
        );
      });
    }
    widget.focusNode.requestFocus();
  }

  void _submit(String raw) {
    final int i = _highlight;
    if (i >= 0 && i < _items.length) {
      widget.onOpenSuggestion(_items[i]);
    } else {
      widget.onSubmitted(raw);
    }
    widget.focusNode.unfocus();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_items.isEmpty) return KeyEventResult.ignored;
    final bool up = widget.direction == WebBrowserSuggestionsDirection.up;
    int delta = 0;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) delta = up ? -1 : 1;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) delta = up ? 1 : -1;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => _highlight = -1);
      _portal.hide();
      return KeyEventResult.handled;
    }
    if (delta == 0) return KeyEventResult.ignored;
    setState(() {
      final int n = _items.length;
      _highlight = _highlight < 0
          ? (delta > 0 ? 0 : n - 1)
          : (_highlight + delta) % n;
    });
    return KeyEventResult.handled;
  }

  Widget _suggestionTile(BuildContext context, int i) {
    final WebBrowserSuggestion s = _items[i];
    final ThemeData theme = Theme.of(context);
    final IconData icon = switch (s.kind) {
      WebBrowserSuggestionKind.bookmark => FushiIcons.star,
      WebBrowserSuggestionKind.history => FushiIcons.history,
      WebBrowserSuggestionKind.search => FushiIcons.search,
    };
    final bool selected = i == _highlight;
    return Material(
      color: selected
          ? theme.colorScheme.secondaryContainer
          : Colors.transparent,
      child: InkWell(
        key: ValueKey<String>('web-browser-suggestion-$i'),
        onTap: () {
          widget.onOpenSuggestion(s);
          widget.focusNode.unfocus();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: <Widget>[
              FushiIcon(icon, size: 18),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      s.title.isEmpty ? (s.url?.toString() ?? '') : s.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                    if (s.url != null)
                      Text(
                        s.url!.toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSuggestions(BuildContext context) {
    final bool up = widget.direction == WebBrowserSuggestionsDirection.up;
    final RenderObject? box = _box.currentContext?.findRenderObject();
    final double width = box is RenderBox && box.hasSize ? box.size.width : 360;
    final ThemeData theme = Theme.of(context);
    return CompositedTransformFollower(
      link: _link,
      showWhenUnlinked: false,
      targetAnchor: up ? Alignment.topLeft : Alignment.bottomLeft,
      followerAnchor: up ? Alignment.bottomLeft : Alignment.topLeft,
      offset: Offset(0, up ? -4 : 4),
      child: Align(
        alignment: up ? Alignment.bottomLeft : Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: Material(
            key: const ValueKey<String>('web-browser-suggestions'),
            elevation: 3,
            color: isGlassDesign(context)
                ? appleColorsOf(context).secondaryGroupedBackground
                : theme.colorScheme.surfaceContainer,
            borderRadius: FushiBorderRadius.menu,
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 6),
                shrinkWrap: true,
                reverse: up,
                itemCount: _items.length,
                itemBuilder: _suggestionTile,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDisplay(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final Color fill = glass
        ? appleColorsOf(context).tertiaryFill
        : theme.colorScheme.surfaceContainerHighest;
    final Color dim = glass
        ? appleColorsOf(context).secondaryLabel
        : theme.colorScheme.onSurfaceVariant;
    final Uri? url = widget.url;
    final TextStyle base = theme.textTheme.bodyMedium ?? const TextStyle();
    final Widget text;
    if (url == null) {
      text = Text(
        t.web_browser_search_hint,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: base.copyWith(color: dim),
      );
    } else {
      final ({String prefix, String host, String rest}) parts =
          webBrowserAddressParts(url);
      text = Text.rich(
        TextSpan(
          children: <InlineSpan>[
            TextSpan(
              text: parts.prefix,
              style: base.copyWith(color: dim),
            ),
            TextSpan(
              text: parts.host,
              style: base.copyWith(fontWeight: FontWeight.w600),
            ),
            TextSpan(
              text: parts.rest,
              style: base.copyWith(color: dim),
            ),
          ],
        ),
        key: const ValueKey<String>('web-browser-address-display'),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
      );
    }
    final bool secure = url?.scheme == 'https';
    return Semantics(
      textField: true,
      label: t.web_browser_search_hint,
      value: url?.toString() ?? '',
      child: Material(
        color: fill,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: beginEditing,
          child: SizedBox(
            height: kFushiSearchFieldHeight,
            child: Row(
              children: <Widget>[
                const SizedBox(width: 12),
                FushiIcon(
                  url == null
                      ? FushiIcons.search
                      : (secure ? FushiIcons.lock : FushiIcons.info),
                  size: kFushiSearchFieldIconSize,
                  color: dim,
                ),
                const SizedBox(width: 8),
                Expanded(child: text),
                ..._trailing(context),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _trailing(BuildContext context) => <Widget>[
    if (widget.onToggleBookmark != null)
      FushiIconButton(
        key: const ValueKey<String>('web-browser-bookmark-toggle'),
        tooltip: widget.bookmarked
            ? t.web_browser_bookmark_remove
            : t.web_browser_bookmark_add,
        icon: widget.bookmarked
            ? FushiIcons.filled(FushiIcons.star)
            : FushiIcons.star,
        selected: widget.bookmarked,
        size: kFushiSearchFieldIconSize,
        padding: const EdgeInsets.all(6),
        onTap: widget.onToggleBookmark,
      ),
    if (widget.onReload != null)
      FushiIconButton(
        key: const ValueKey<String>('web-browser-reload'),
        tooltip: t.refresh,
        icon: FushiIcons.refresh,
        size: kFushiSearchFieldIconSize,
        padding: const EdgeInsets.all(6),
        onTap: widget.onReload,
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final Widget field = _editing
        ? Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: _onKey,
            child: FushiSearchField(
              fieldKey: const ValueKey<String>('web-browser-address'),
              controller: _text,
              focusNode: widget.focusNode,
              hintText: t.web_browser_search_hint,
              keyboardType: TextInputType.url,
              autofocus: true,
              leading: const FushiSearchLeading(
                child: FushiIcon(FushiIcons.search),
              ),
              onClear: () {
                _text.clear();
                unawaited(widget.suggestions.update(''));
              },
              onChanged: (String value) {
                _highlight = -1;
                unawaited(widget.suggestions.update(value));
              },
              onSubmitted: _submit,
            ),
          )
        : KeyedSubtree(
            key: const ValueKey<String>('web-browser-address'),
            child: _buildDisplay(context),
          );
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: _buildSuggestions,
        child: KeyedSubtree(
          key: _box,
          child: AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.short),
            child: field,
          ),
        ),
      ),
    );
  }
}
