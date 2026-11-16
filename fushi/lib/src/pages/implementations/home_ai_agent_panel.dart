/// 首页「AI 助手」入口条（[HomeDashboardPanel.aiAgent]，spec 2026-10-26 D4 ①）：
/// 「AI 助手」+ 一个真输入框（[HomeAiAgentInput]）。在框里打字回车 / 点发送 =
/// 打开 AI 浮层并把这句话直接发出；点块上输入框以外的地方 = 只打开浮层（与悬浮球
/// 「AI」同一个入口 [openAiAgent]）。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/ai/agent/ai_agent_controller.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_dashboard_panel.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/ai_agent_page.dart';
import 'package:fushi/src/shortcuts/input_binding.dart' show InputBinding;
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart'
    show isDesktopPlatform;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiIconButtonControl;
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart'
    show FushiTextFieldControl;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show FushiCoverBlockColors, FushiCoverBlockSize, fushiCoverBlockShape;
import 'package:fushi/src/utils/components/fushi_poster_block.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart'
    show shelfCoverCard;

/// AI 助手条该不该出现在首页（纯函数，判据的唯一实现）。
///
/// - AI 模块关着：恒不显示。
/// - 用户钉了显示 / 隐藏：照办（钉了显示但没指派提供商时照样出，点了引导去设置）。
/// - 自动：给「AI 助手」指派了可用的提供商才出（没配 AI 的人首页不多一栏）。
bool resolveHomeAiAgentPanelVisible({
  required bool moduleEnabled,
  required HomeDashboardPanelMode mode,
  required bool hasProvider,
}) {
  if (!moduleEnabled) return false;
  return switch (mode) {
    HomeDashboardPanelMode.shown => true,
    HomeDashboardPanelMode.hidden => false,
    HomeDashboardPanelMode.auto => hasProvider,
  };
}

/// [resolveHomeAiAgentPanelVisible] 的 Riverpod 装配。
final Provider<bool> homeAiAgentPanelVisibleProvider = Provider<bool>((
  Ref ref,
) {
  final AppModel app = ref.watch(appProvider);
  if (!app.isPreferencesReady) return false;
  return resolveHomeAiAgentPanelVisible(
    moduleEnabled: app.moduleVisibility.isEnabled(ModuleId.ai),
    mode: app.homeDashboardPanelMode(HomeDashboardPanel.aiAgent),
    hasProvider: resolveAiAgentProvider(app.prefsRepo) != null,
  );
});

/// 首页 AI 助手条。显隐由 dashboard 按 [homeAiAgentPanelVisibleProvider] 决定。
class HomeAiAgentPanel extends StatelessWidget {
  const HomeAiAgentPanel({
    super.key,
    this.poster = false,
    this.height,
    this.opener = openAiAgent,
  });

  static const double rowHeight = 44;

  /// true = 重设计外壳的海报色块形态（「AI 助手」chip + 大字标题 + 输入提示，
  /// 点色块打开 AI 浮层）；false = 原一行条。由首页按外壳门控传入。
  final bool poster;

  /// 拼贴色块的固定高（与并排的追踪块等高，设计稿 H6 / H7）；null = 按内容高。
  final double? height;

  /// 打开 AI 浮层的入口（默认 [openAiAgent]；测试注入）。
  final HomeAiAgentOpener opener;

  /// 拼贴色块形态（设计稿 H7）：左上「AI 助手」小标签，块内一条胶囊输入框
  /// （[HomeAiAgentInput]：占位提示语 + 桌面上「呼出 AI 助手」的快捷键），大字
  /// 水印只用「AI」两个字母（装进末端半块，不再是被截断的「AI 助手」）。胶囊里
  /// 能直接打字发给 AI；点块上胶囊以外的地方打开 AI 浮层。
  Widget _buildPoster(BuildContext context) {
    final FushiCoverBlockColors colors = fushiPosterColors(
      context,
      fushiPosterHue('home-ai-agent'),
    );
    final TextStyle base =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final Color muted = colors.onContainer.withValues(alpha: 0.8);
    final double? fixed = height;
    final Widget content = Consumer(
      builder: (BuildContext context, WidgetRef ref, Widget? _) {
        final AppModel app = ref.watch(appProvider);
        final List<InputBinding> keys = app.shortcutRegistry
            .bindingsFor(ShortcutAction.globalOpenAiAssistant)
            .keyboardBindings;
        final String? shortcut = isDesktopPlatform && keys.isNotEmpty
            ? keys.first.displayLabel
            : null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: fixed == null ? MainAxisSize.min : MainAxisSize.max,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Row(
              spacing: 6,
              children: <Widget>[
                FushiIcon(FushiIcons.aiAssistant, size: 14, color: muted),
                Flexible(
                  child: Text(
                    t.ai_agent_title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: FushiPosterText.meta.on(base).copyWith(color: muted),
                  ),
                ),
              ],
            ),
            if (fixed == null) const SizedBox(height: 16),
            DecoratedBox(
              key: const ValueKey<String>('home-ai-agent-panel-input'),
              decoration: ShapeDecoration(
                shape: const StadiumBorder(),
                color: colors.onContainer.withValues(alpha: 0.12),
              ),
              child: Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: 16,
                  end: 6,
                  top: 4,
                  bottom: 4,
                ),
                child: HomeAiAgentInput(
                  textStyle: FushiPosterText.caption
                      .on(base)
                      .copyWith(color: colors.onContainer),
                  hintColor: muted,
                  shortcutLabel: shortcut,
                  shortcutStyle: FushiPosterText.badge
                      .on(base)
                      .copyWith(
                        color: colors.onContainer.withValues(alpha: 0.6),
                      ),
                  opener: opener,
                ),
              ),
            ),
          ],
        );
      },
    );
    final Widget poster = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) => FushiPosterBlock(
        watermark: 'AI',
        watermarkEdge: FushiPosterWatermarkEdge.bottom,
        watermarkStart: box.maxWidth.isFinite ? box.maxWidth * 0.55 : 0,
        watermarkFontSize: 90,
        colors: colors,
        padding: const EdgeInsets.all(16),
        child: fixed == null
            ? content
            : SizedBox(height: fixed - 32, child: content),
      ),
    );
    return KeyedSubtree(
      key: const ValueKey<String>('home-ai-agent-panel'),
      // 整块按钮读「AI 助手」；块内输入框自带占位提示的语义，这里不再重复读一遍。
      child: Semantics(
        label: t.ai_agent_title,
        child: SizedBox(
          height: fixed,
          child: shelfCoverCard(
            key: const ValueKey<String>('home-ai-agent-panel-open'),
            shape: fushiCoverBlockShape(context, FushiCoverBlockSize.regular),
            onTap: () => unawaited(opener(context)),
            child: poster,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (poster) return _buildPoster(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool apple = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final BorderRadius radius = apple
        ? FushiAppleMetrics.of(context).groupBorderRadius
        : FushiBorderRadius.card;
    final Color fill = apple
        ? appleColorsOf(context).secondaryGroupedBackground
        : tokens.surfaces.group;
    return FushiHoverLift(
      scale: 1.01,
      builder: (BuildContext context, bool hovering) => FushiPressScale(
        child: Material(
          key: const ValueKey<String>('home-ai-agent-panel'),
          color: fill,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: eink
                ? BorderSide(color: tokens.surfaces.outline)
                : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey<String>('home-ai-agent-panel-open'),
            onTap: () => unawaited(opener(context)),
            child: Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                tokens.spacing.gap + 4,
                tokens.spacing.gap / 2,
                tokens.spacing.gap + 4,
                tokens.spacing.gap / 2,
              ),
              child: SizedBox(
                height: rowHeight,
                child: Row(
                  children: <Widget>[
                    FushiIcon(
                      FushiIcons.aiAssistant,
                      size: 18,
                      color: tokens.type.sectionLabel.color,
                    ),
                    SizedBox(width: tokens.spacing.gap / 2),
                    Text(
                      t.ai_agent_title,
                      maxLines: 1,
                      style: tokens.type.sectionLabel,
                    ),
                    SizedBox(width: tokens.spacing.gap),
                    Expanded(
                      child: HomeAiAgentInput(
                        textStyle: tokens.type.listSubtitle,
                        hintColor:
                            tokens.type.metadata.color ??
                            Theme.of(context).hintColor,
                        opener: opener,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 打开 AI 浮层：[initialPrompt] 非空时浮层就绪后把它当第一句话直接发出
/// （[openAiAgent] 的签名子集，测试注入替身）。返回浮层是否真的开过：false =
/// 没开（没指派提供商只引导去设置），那句话没发出去。
typedef HomeAiAgentOpener =
    Future<bool> Function(BuildContext context, {String? initialPrompt});

/// 首页 AI 块里的真输入框：占位是「告诉 AI 要做什么…」，桌面上空着时尾部挂
/// 「呼出 AI 助手」的快捷键提示，有字时换成发送按钮。回车 / 点发送把这句话交给
/// [opener]（打开浮层并直接发出），然后清空、交还焦点；空着回车就只打开浮层。
///
/// 键盘焦点：框持焦时打字不触发首页 / 全局快捷键——首页整页 key sink 与全局「呼出
/// AI 助手」都先问 `keyTypesIntoFocusedTextField`，可打印字符归文本框；回车在本框
/// 的键事件层认领为提交、空格由文本框的 `DoNothingAndStopPropagationTextIntent`
/// 截住，都不会冒泡去激活外层整块的点按目标。没指派提供商时 [openAiAgent] 只引导
/// 去设置、不发请求。
class HomeAiAgentInput extends StatefulWidget {
  const HomeAiAgentInput({
    required this.textStyle,
    required this.hintColor,
    this.shortcutLabel,
    this.shortcutStyle,
    this.opener = openAiAgent,
    super.key,
  });

  /// 输入文字的样式（占位提示语同字号，换 [hintColor]）。
  final TextStyle textStyle;
  final Color hintColor;

  /// 「呼出 AI 助手」快捷键的显示文字；null = 不显示（移动端 / 没绑键）。
  final String? shortcutLabel;
  final TextStyle? shortcutStyle;

  final HomeAiAgentOpener opener;

  @override
  State<HomeAiAgentInput> createState() => _HomeAiAgentInputState();
}

class _HomeAiAgentInputState extends State<HomeAiAgentInput> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode(debugLabel: 'home-ai-agent-input');
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final bool hasText = _controller.text.trim().isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
  }

  Future<void> _submit() async {
    final String text = _controller.text.trim();
    _controller.clear();
    // 焦点交给即将打开的浮层输入框；留在这里的话浮层关掉后首页输入框还持焦。
    _focus.unfocus();
    final bool opened = await widget.opener(
      context,
      initialPrompt: text.isEmpty ? null : text,
    );
    // 浮层没开（没指派提供商，只引导去了设置）：这句话没发出去，原样还回输入框，
    // 配好 AI 回来还能直接发；用户这期间又打了新字就不覆盖。
    if (!opened && text.isNotEmpty && mounted && _controller.text.isEmpty) {
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  KeyEventResult _onFieldKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent ||
        (event.logicalKey != LogicalKeyboardKey.enter &&
            event.logicalKey != LogicalKeyboardKey.numpadEnter)) {
      return KeyEventResult.ignored;
    }
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isShiftPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        !_focus.hasFocus ||
        _controller.value.composing.isValid) {
      return KeyEventResult.ignored;
    }
    unawaited(_submit());
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final String? shortcut = widget.shortcutLabel;
    final Widget trailing;
    if (_hasText) {
      trailing = FushiPressScale(
        key: const ValueKey<String>('home-ai-agent-panel-send'),
        child: FushiIconButtonControl(
          tooltip: t.ai_agent_send,
          onPressed: () => unawaited(_submit()),
          color: widget.textStyle.color,
          icon: FushiIcon(
            isGlassDesign(context) ? FushiIcons.arrowUp : FushiIcons.forward,
            size: 18,
          ),
        ),
      );
    } else if (shortcut != null) {
      trailing = Padding(
        key: const ValueKey<String>('home-ai-agent-panel-shortcut-slot'),
        padding: const EdgeInsetsDirectional.only(start: 10, end: 10),
        child: Text(
          shortcut,
          key: const ValueKey<String>('home-ai-agent-panel-shortcut'),
          maxLines: 1,
          style:
              widget.shortcutStyle ??
              widget.textStyle.copyWith(color: widget.hintColor),
        ),
      );
    } else {
      trailing = const SizedBox.shrink(
        key: ValueKey<String>('home-ai-agent-panel-trailing-empty'),
      );
    }
    return Row(
      children: <Widget>[
        Expanded(
          // 物理回车在键事件层认领（与 FushiSearchBar 的 BUG-2620 兜底同一判据）：
          // 桌面端提交动作要穿过引擎的 text input 插件，没走到就是「按回车没反应」；
          // 认领后 handled 也挡住外层整块的激活。带修饰键、IME 组字中的回车放行。
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: _onFieldKey,
            child: FushiTextFieldControl(
              key: const ValueKey<String>('home-ai-agent-panel-field'),
              controller: _controller,
              focusNode: _focus,
              maxLines: 1,
              textInputAction: TextInputAction.send,
              onSubmitted: (String _) => unawaited(_submit()),
              style: widget.textStyle,
              cursorColor: widget.textStyle.color,
              decoration: InputDecoration(
                hintText: t.ai_agent_input_hint,
                hintMaxLines: 1,
                hintStyle: widget.textStyle.copyWith(color: widget.hintColor),
                border: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
        ),
        AnimatedSwitcher(
          duration: fushiMotionDuration(context, FushiMotion.short),
          switchInCurve: FushiMotion.enter,
          switchOutCurve: FushiMotion.exit,
          transitionBuilder: (Widget child, Animation<double> animation) =>
              FadeTransition(
                opacity: animation,
                child: ScaleTransition(scale: animation, child: child),
              ),
          child: trailing,
        ),
      ],
    );
  }
}
