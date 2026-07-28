/// 窗口超分的档位选择对话框 —— galgame 库里对着一个游戏改它自己的超分档。
///
/// 为什么超分没有设置项（BUG-1191）：它是**每个游戏各自**的东西。同一个人手上有需要
/// 超分的 800×600 老 gal，也有本身就 1080p 的新作；一个全局开关只能两边都不对。所以
/// 档位存在 galgame 库那一行上，入口就在游戏卡片的右键菜单里（与「重命名」「设置封面」
/// 「标签」同一处）—— 用户在哪儿管这个游戏，就在哪儿改它的超分。
///
/// 单独成文件的理由同 `magpie_download_confirm.dart`：让 [MagpieUpscalingService] 保持
/// 零 UI 依赖（不持 BuildContext、不引 i18n、不碰 DB），这样它才能被单测直接构造。
library;

import 'package:flutter/material.dart';
import 'package:hibiki/src/mining/magpie_upscaling.dart';
import 'package:hibiki/utils.dart';

/// 让用户为某个游戏挑一档。返回 null = 用户取消（**不写任何东西**，保持原档）。
///
/// [current] 是这个游戏当前的档位；调用方负责持久化返回值。
Future<MagpieUpscalingMode?> pickMagpieUpscalingMode(
  BuildContext context, {
  required MagpieUpscalingMode current,
  required String gameName,
}) =>
    showAppDialog<MagpieUpscalingMode>(
      context: context,
      builder: (BuildContext dialogContext) => MagpieUpscalingModeDialog(
        current: current,
        gameName: gameName,
      ),
    );

/// 三档单选对话框。每档都写清代价，范式同工作台的「音频降级策略」——这不是「高级
/// 选项」，是用户按自己机器和这个游戏的分辨率来定的判断。
class MagpieUpscalingModeDialog extends StatelessWidget {
  const MagpieUpscalingModeDialog({
    super.key,
    required this.current,
    required this.gameName,
  });

  /// 这个游戏当前的档位。没设过的游戏传 [kMagpieDefaultUpscalingMode]（关闭）。
  final MagpieUpscalingMode current;

  /// 游戏显示名，写进标题——菜单里同时能开好几个游戏的对话框，不写名字用户认不出
  /// 自己在改哪个。
  final String gameName;

  static String modeLabel(MagpieUpscalingMode mode) {
    switch (mode) {
      case MagpieUpscalingMode.auto:
        return t.game_upscaling_auto;
      case MagpieUpscalingMode.installedOnly:
        return t.game_upscaling_installed_only;
      case MagpieUpscalingMode.off:
        return t.game_upscaling_off;
    }
  }

  static String _modeHint(MagpieUpscalingMode mode) {
    switch (mode) {
      case MagpieUpscalingMode.auto:
        return t.game_upscaling_auto_hint;
      case MagpieUpscalingMode.installedOnly:
        return t.game_upscaling_installed_only_hint;
      case MagpieUpscalingMode.off:
        return t.game_upscaling_off_hint;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.game_upscaling_pick_title(name: gameName)),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  t.game_upscaling_pick_body,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              for (final MagpieUpscalingMode mode in MagpieUpscalingMode.values)
                RadioListTile<MagpieUpscalingMode>(
                  key: ValueKey<String>(
                    'magpie-upscaling-mode-${magpieUpscalingModeToKey(mode)}',
                  ),
                  value: mode,
                  groupValue: current,
                  contentPadding: EdgeInsets.zero,
                  title: Text(modeLabel(mode)),
                  subtitle: Text(_modeHint(mode)),
                  onChanged: (MagpieUpscalingMode? picked) =>
                      Navigator.of(context).pop(picked),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
