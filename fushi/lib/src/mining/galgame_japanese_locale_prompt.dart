/// 日语区域（转区）的档位选择对话框 —— 对着一个游戏改它自己的转区档。
///
/// 为什么是每游戏而不是全局开关（BUG-1477）：同一个库里日文原版和汉化版并存。
/// 日文原版不转区会满屏乱码，汉化版转区会**启动即闪退**（它恰好是 32 位老引擎，
/// 但字符串已转成 GBK/UTF-8，套 CP932 让游戏解出非法序列、字表索引越界）。
/// 一个全局开关只能两边都不对。形状与 [MagpieUpscalingModeDialog] 完全一致——
/// 这是本仓已经为同形问题定过案的结论（BUG-1191），不是另起一套。
///
/// 单独成文件是为了让 `galgame_japanese_locale.dart` 保持零 UI 依赖（纯函数 +
/// 一个 FFI 探针），可被单测直接调用。
library;

import 'package:flutter/material.dart';
import 'package:fushi/src/mining/galgame_japanese_locale.dart';
import 'package:fushi/utils.dart';

/// 让用户为某个游戏挑一档。返回 null = 用户取消（**不写任何东西**，保持原档）。
Future<GalJapaneseLocaleMode?> pickGalJapaneseLocaleMode(
  BuildContext context, {
  required GalJapaneseLocaleMode current,
  required String gameName,
}) =>
    showAppDialog<GalJapaneseLocaleMode>(
      context: context,
      builder: (BuildContext dialogContext) => GalJapaneseLocaleModeDialog(
        current: current,
        gameName: gameName,
      ),
    );

class GalJapaneseLocaleModeDialog extends StatelessWidget {
  const GalJapaneseLocaleModeDialog({
    super.key,
    required this.current,
    required this.gameName,
  });

  /// 这个游戏当前的档位。没设过的游戏传 [kGalDefaultJapaneseLocaleMode]（auto）。
  final GalJapaneseLocaleMode current;

  /// 游戏显示名，写进标题——菜单里同时能开好几个游戏的对话框，不写名字用户认不出
  /// 自己在改哪个。
  final String gameName;

  static String modeLabel(GalJapaneseLocaleMode mode) {
    switch (mode) {
      case GalJapaneseLocaleMode.auto:
        return t.game_japanese_locale_auto;
      case GalJapaneseLocaleMode.on:
        return t.game_japanese_locale_on;
      case GalJapaneseLocaleMode.off:
        return t.game_japanese_locale_off;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${t.game_japanese_locale} · $gameName'),
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
                  t.game_japanese_locale_hint,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              for (final GalJapaneseLocaleMode mode
                  in GalJapaneseLocaleMode.values)
                RadioListTile<GalJapaneseLocaleMode>(
                  key: ValueKey<String>(
                    'gal-japanese-locale-mode-'
                    '${galJapaneseLocaleModeToKey(mode)}',
                  ),
                  value: mode,
                  groupValue: current,
                  contentPadding: EdgeInsets.zero,
                  title: Text(modeLabel(mode)),
                  onChanged: (GalJapaneseLocaleMode? picked) =>
                      Navigator.of(context).pop(picked),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
