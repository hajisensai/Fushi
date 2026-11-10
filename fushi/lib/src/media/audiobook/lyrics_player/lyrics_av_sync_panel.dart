// 歌词模式「音画同步」快捷面板（反馈 G5xYgLcp4p，#3109 遗留：调整体同步偏移要
// 离开歌词模式去 设置 › 有声书，来回切太麻烦）。
//
// 覆盖层上的同步键（[LyricsControlItem.avSync]）或 ⋯ 菜单里的同名项点开，与倍速 /
// 「Aa」面板同一条锚定路由 [showLyricsAnchoredPanel]。内容就是普通阅读模式快捷设置
// 那一行 [AudiobookAvSyncStepper]——同一组件、同一步进（±50ms / ±1s，按住连续）、
// 回调同一个 `AudiobookPlayerController.setDelayMs`（夹取 + 立即重查高亮 + 写同一个
// 偏好，不另存）。偏移即时作用于高亮、点句跳转、单句试听、上下句与制卡片段。
//
// 只调**整本**偏移；功能黑名单禁止逐行偏移 / 歌词编辑，这里不做。
//
// 键盘 / 手柄：面板打开即持有焦点，←/→ 按 50ms 一步、Shift+←/→ 按 1s 一步，
// Tab 到各键 Enter 触发，Esc / 手柄 B / 点面板外关闭，焦点回到触发键。
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/audiobook_av_sync_stepper.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_speed_panel.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_glass_surface.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 面板根节点 key（测试用）。
const ValueKey<String> kLyricsAvSyncPanelKey = ValueKey<String>(
  'lyrics_av_sync_panel',
);

/// 面板里「归零」键的 key。
const ValueKey<String> kLyricsAvSyncPanelResetKey = ValueKey<String>(
  'lyrics_av_sync_panel_reset',
);

/// 从 [anchorContext]（同步键或 ⋯ 键）弹出同步面板。[delayMs] 是控制器的偏移
/// 通知器，[onChanged] 收到未夹取的新偏移（实时生效）；面板关闭时 Future 完成。
Future<void> showLyricsAvSyncPanel({
  required BuildContext anchorContext,
  required ValueListenable<int> delayMs,
  required ValueChanged<int> onChanged,
}) {
  return showLyricsAnchoredPanel(
    anchorContext: anchorContext,
    builder: (BuildContext context) =>
        LyricsAvSyncPanel(delayMs: delayMs, onChanged: onChanged),
  );
}

/// 同步面板本体（两套设计系统共用骨架；表面走 [FushiGlassSurface]）。公开是为了
/// 让行为测试直接 pump。
class LyricsAvSyncPanel extends StatelessWidget {
  const LyricsAvSyncPanel({
    required this.delayMs,
    required this.onChanged,
    super.key,
  });

  /// 当前偏移（控制器的通知器：读数跟着控制器夹取后的真实值走）。
  final ValueListenable<int> delayMs;

  /// 新偏移（毫秒，未夹取）。
  final ValueChanged<int> onChanged;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final int direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowLeft => -1,
      LogicalKeyboardKey.arrowRight => 1,
      _ => 0,
    };
    if (direction == 0) return KeyEventResult.ignored;
    final int step = HardwareKeyboard.instance.isShiftPressed
        ? AudiobookAvSyncStepper.coarseStepMs
        : AudiobookAvSyncStepper.fineStepMs;
    onChanged(delayMs.value + direction * step);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final ColorScheme scheme = theme.colorScheme;
    final FushiAppleColors? apple = glass ? appleColorsOf(context) : null;
    final Color fg = apple?.label ?? scheme.onSurface;
    final Color secondary = apple?.secondaryLabel ?? scheme.onSurfaceVariant;

    final Widget body = Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              // M3E 行首形状底；Apple 自动退成 iOS 设置式彩色圆角方块。
              const FushiListLeadingIcon(
                FushiIcons.sync,
                shape: FushiLeadingShape.cookie,
                tone: FushiCardTone.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  t.av_sync,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              ValueListenableBuilder<int>(
                valueListenable: delayMs,
                builder: (BuildContext context, int ms, Widget? _) =>
                    FushiTextButton.icon(
                      key: kLyricsAvSyncPanelResetKey,
                      onPressed: ms == 0 ? null : () => onChanged(0),
                      icon: const FushiIcon(FushiIcons.restart),
                      label: Text(t.av_sync_reset),
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: AudiobookAvSyncStepper(
                delayMs: delayMs,
                onChanged: onChanged,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            t.lyrics_av_sync_hint,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: secondary),
          ),
        ],
      ),
    );

    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: t.av_sync,
      child: Focus(
        key: kLyricsAvSyncPanelKey,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Material(
          type: MaterialType.transparency,
          child: FushiGlassSurface(
            borderRadius: BorderRadius.all(Radius.circular(glass ? 22 : 28)),
            child: body,
          ),
        ),
      ),
    );
  }
}
