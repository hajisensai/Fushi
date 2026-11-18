/// 首页「AI 助手」小组件（[HomeWidgetKind.aiAgent]，spec 2026-10-26 D4 ①；首页小组件
/// 网格 2026-11-15）：「AI 助手」+ 一个真输入框（[HomeAiAgentInput]）。在框里打字
/// 回车 / 点发送 = 打开 AI 浮层并把这句话直接发出；点块上输入框以外的地方 = 只打开
/// 浮层（与悬浮球「AI」同一个入口 [openAiAgent]）。格子太矮 / 太窄放不下输入框时
/// 退回「告诉 AI 要做什么… ›」提示行，点了同样打开浮层。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/ai/agent/ai_agent_controller.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/ai_agent_page.dart';
import 'package:fushi/src/pages/implementations/home_widget_frame.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/shortcuts/input_binding.dart' show InputBinding;
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart'
    show isDesktopPlatform;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_poster_block.dart'
    show FushiPosterText;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiIconButtonControl;
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart'
    show FushiTextFieldControl;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';

/// AI 助手组件此刻可不可用（纯函数，判据的唯一实现）：只看 AI 模块门。
///
/// 未指派提供商**不算**不可用（fushi/CLAUDE.md §13：入口可见，点击引导去设置）——
/// 组件照常渲染，点了走 [openAiAgent]，由它提示并引导去「设置 › AI」，不发请求。
bool resolveHomeAiAgentWidgetAvailable({required bool moduleEnabled}) =>
    moduleEnabled;

/// [resolveHomeAiAgentWidgetAvailable] 的 Riverpod 装配。
final Provider<bool> homeAiAgentWidgetAvailableProvider = Provider<bool>((
  Ref ref,
) {
  final AppModel app = ref.watch(appProvider);
  if (!app.isPreferencesReady) return false;
  return resolveHomeAiAgentWidgetAvailable(
    moduleEnabled: app.moduleVisibility.isEnabled(ModuleId.ai),
  );
});

/// 旧可选面板「自动」档的判据（迁移首个布局 / 恢复默认时决定默认模板放不放 AI
/// 助手）：模块开着且给「AI 助手」指派了可用的提供商。只影响默认放不放，不影响
/// 已放上的组件显不显示。
bool resolveHomeAiAgentAutoDefault({
  required bool moduleEnabled,
  required bool hasProvider,
}) => moduleEnabled && hasProvider;

/// [resolveHomeAiAgentAutoDefault] 的 Riverpod 装配。
final Provider<bool> homeAiAgentAutoDefaultProvider = Provider<bool>((Ref ref) {
  final AppModel app = ref.watch(appProvider);
  if (!app.isPreferencesReady) return false;
  return resolveHomeAiAgentAutoDefault(
    moduleEnabled: app.moduleVisibility.isEnabled(ModuleId.ai),
    hasProvider: resolveAiAgentProvider(app.prefsRepo) != null,
  );
});

/// 首页 AI 助手小组件（1×1…3×2，提示文字按格子高度放几行）。可不可用由首页按
/// [homeAiAgentWidgetAvailableProvider] 决定。
class HomeAiAgentPanel extends StatelessWidget {
  const HomeAiAgentPanel({
    super.key,
    this.poster = false,
    this.opener = openAiAgent,
  });

  /// true = 海报色块外观。
  final bool poster;

  /// 打开 AI 浮层的入口（默认 [openAiAgent]；测试注入）。
  final HomeAiAgentOpener opener;

  /// 输入框最少要这么宽才放（再窄退回提示行）。
  static const double _kInputMinWidth = 160;

  /// 块内的真输入框：海报色块是一条半透明胶囊（拼贴设计稿 H7，桌面上空着时尾部
  /// 挂「呼出 AI 助手」的快捷键），分区卡是无底的一行。
  Widget _buildInput(
    BuildContext context,
    HomeWidgetStyle style,
    TextStyle base,
  ) {
    final Color? onBlock = style.colors?.onContainer;
    if (onBlock == null) {
      return HomeAiAgentInput(
        key: const ValueKey<String>('home-ai-agent-panel-input'),
        textStyle: context.fushiType.bodyMedium.copyWith(
          color: style.foreground,
        ),
        hintColor: style.muted,
        opener: opener,
      );
    }
    return Consumer(
      builder: (BuildContext context, WidgetRef ref, Widget? _) {
        final AppModel app = ref.watch(appProvider);
        final List<InputBinding> keys = app.shortcutRegistry
            .bindingsFor(ShortcutAction.globalOpenAiAssistant)
            .keyboardBindings;
        final String? shortcut = isDesktopPlatform && keys.isNotEmpty
            ? keys.first.displayLabel
            : null;
        return DecoratedBox(
          key: const ValueKey<String>('home-ai-agent-panel-input'),
          decoration: ShapeDecoration(
            shape: const StadiumBorder(),
            color: onBlock.withValues(alpha: 0.12),
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
                  .copyWith(color: onBlock),
              hintColor: style.muted,
              shortcutLabel: shortcut,
              shortcutStyle: FushiPosterText.badge
                  .on(base)
                  .copyWith(color: onBlock.withValues(alpha: 0.6)),
              opener: opener,
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final bool dense = homeWidgetIsDense(c.maxHeight);
        return HomeWidgetFrame(
          key: const ValueKey<String>('home-ai-agent-panel'),
          tapKey: const ValueKey<String>('home-ai-agent-panel-open'),
          title: t.ai_agent_title,
          icon: FushiIcons.aiAssistant,
          hueKey: HomeWidgetKind.aiAgent.id,
          poster: poster,
          dense: dense,
          // 拼贴色块的幽灵大字只用「AI」两个字母，装进末端半块（不再是被截断的
          // 「AI 助手」）。
          watermark: 'AI',
          watermarkStartFactor: 0.55,
          onTap: () => unawaited(opener(context)),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints box) {
              final HomeWidgetStyle style = HomeWidgetStyle.of(context);
              final TextStyle base =
                  Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
              final double inputHeight =
                  MediaQuery.textScalerOf(context).scale(14) * 1.4 + 24;
              if (!dense &&
                  box.maxWidth >= _kInputMinWidth &&
                  box.maxHeight >= inputHeight) {
                return Align(
                  alignment: AlignmentDirectional.bottomStart,
                  child: _buildInput(context, style, base),
                );
              }
              final FushiTypography type = context.fushiType;
              final TextStyle hintStyle =
                  (dense ? type.bodyMedium : type.bodyLarge).copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                    color: style.accent,
                  );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                spacing: 6,
                children: <Widget>[
                  Expanded(
                    child: Align(
                      alignment: AlignmentDirectional.bottomStart,
                      child: Text(
                        t.ai_agent_input_hint,
                        // 格子越高放越多行；按行高算，不溢出。
                        maxLines: homeWidgetLinesFor(
                          box.maxHeight,
                          homeWidgetLineHeight(context, hintStyle),
                          max: 6,
                        ),
                        overflow: TextOverflow.ellipsis,
                        style: hintStyle,
                      ),
                    ),
                  ),
                  FushiIcon(FushiIcons.forward, size: 20, color: style.accent),
                ],
              );
            },
          ),
        );
      },
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
