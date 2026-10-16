/// 设置项控制通道（`fushi_cli config get/set`）读写自绘行时共用的值写法。
library;

/// 「跟随主题」的写法（颜色行）。
const String kSettingsCliFollowTheme = 'theme';

/// 颜色写法：`#AARRGGBB` / `#RRGGBB`（不带 alpha 视为不透明）/ `0xAARRGGBB`。
/// 不合法抛 [FormatException]。
int parseSettingsCliColor(String raw) {
  String text = raw.trim();
  if (text.startsWith('#')) {
    text = text.substring(1);
  } else if (text.toLowerCase().startsWith('0x')) {
    text = text.substring(2);
  }
  if (!RegExp(r'^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$').hasMatch(text)) {
    throw FormatException('颜色写成 #RRGGBB 或 #AARRGGBB，收到「$raw」');
  }
  final int value = int.parse(text, radix: 16);
  return text.length == 6 ? 0xFF000000 | value : value;
}

/// 颜色的展示 / 回写形式：`#AARRGGBB`（大写）。
String formatSettingsCliColor(int argb) =>
    '#${(argb & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0').toUpperCase()}';
