import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

/// 用户导入字体的「实际字面字重」与「是否会被合成假粗体」判据。
///
/// 字体库每个文件条目在 `AppFontLoader` 里各自注册成一个 family，且只有那一个
/// face（一个文件 = 一个字重）。对这样的 family 请求比 face 重得多的字重时，
/// 引擎找不到对应字面就合成假粗体：Android minikin / Skia 在
/// `请求字重 >= 600 且 请求 - 实际 >= 200` 时把笔画向外描边加粗——手写体 / 细笔画
/// 字体会糊成一团（反馈 KuZmUL3U-l，复习卡词头 w600、例句加粗段 w700）。
///
/// 判据只在这里写一次：卡面各处的强调字重都走 [faceSafeFontWeight] /
/// [withFaceSafeWeight]，不各写一份。

/// OS/2 表 tag。
const int _kTagOs2 = 0x4F532F32; // 'OS/2'

/// TTC 头 tag。
const int _kTagTtcf = 0x74746366; // 'ttcf'

/// 从整字体字节读第一个 face 的 OS/2 `usWeightClass`（1..1000）。
///
/// TTC 取第 0 个 face（`FontLoader` 注册的就是它）。无 OS/2 表、越界、
/// 值不在 1..1000 时返回 null（= 未知，调用方按「有完整字重」处理，不改行为）。
int? sfntWeightClass(Uint8List bytes) {
  final ByteData data = ByteData.sublistView(bytes);
  final int length = data.lengthInBytes;
  if (length < 12) return null;
  int base = 0;
  if (data.getUint32(0) == _kTagTtcf) {
    if (length < 16 || data.getUint32(8) == 0) return null;
    base = data.getUint32(12);
  }
  if (base + 12 > length) return null;
  final int numTables = data.getUint16(base + 4);
  if (numTables <= 0 || numTables > 512) return null;
  for (int i = 0; i < numTables; i++) {
    final int rec = base + 12 + i * 16;
    if (rec + 16 > length) return null;
    if (data.getUint32(rec) != _kTagOs2) continue;
    final int off = data.getUint32(rec + 8);
    final int len = data.getUint32(rec + 12);
    // usWeightClass 在 OS/2 表偏移 4（uint16）。
    if (len < 6 || off + 6 > length) return null;
    final int weight = data.getUint16(off + 4);
    return weight >= 1 && weight <= 1000 ? weight : null;
  }
  return null;
}

/// 引擎是否会为 [requested] 合成假粗体：family 只有字重为 [available] 的 face。
///
/// 与 minikin `FontFakery` / Skia 的判据一致：请求 >= 600 且比实际重 >= 200。
bool wouldSynthesizeBold({required int requested, required int available}) =>
    requested >= 600 && requested - available >= 200;

/// 已注册进引擎的用户字体 family → 其唯一 face 的字重（`AppFontLoader` 注册时登记）。
///
/// 只登记**单 face 的文件字体**；系统字体（按名解析、通常有完整字重）与读不出字重
/// 的不登记——查不到 = 按有完整字重处理，保持原行为。
class FontFaceWeightRegistry {
  FontFaceWeightRegistry._();

  static final Map<String, int> _weights = <String, int>{};

  /// 登记 [family] 唯一 face 的字重；[weight] 为 null（读不出）时清掉旧记录。
  static void register(String family, int? weight) {
    if (weight == null) {
      _weights.remove(family);
    } else {
      _weights[family] = weight;
    }
  }

  /// [family] 唯一 face 的字重；未登记返回 null。
  static int? weightOf(String family) => _weights[family];

  @visibleForTesting
  static void resetForTesting() => _weights.clear();
}

/// 给 [family] 请求 [wanted] 时实际该写进 `TextStyle.fontWeight` 的字重。
///
/// [family] 是单 face 的用户字体、且请求会触发假粗体时返回 null——保留字体自己的
/// 字重（与卡面正文「用户自选字体保持其原字重」一致），强调交给字号 / 强调色；
/// 其余（系统字体、未知字重、字体本身够粗）原样返回 [wanted]。
FontWeight? faceSafeFontWeight(String? family, FontWeight wanted) {
  if (family == null) return wanted;
  final int? available = FontFaceWeightRegistry.weightOf(family);
  if (available == null) return wanted;
  return wouldSynthesizeBold(requested: wanted.value, available: available)
      ? null
      : wanted;
}

/// [style] 换上按其主字体 [TextStyle.fontFamily] 判过的强调字重 [wanted]。
///
/// 不会合成假粗体时等价于 `style.copyWith(fontWeight: wanted)`；会时保持
/// [style] 原有字重不变。
TextStyle withFaceSafeWeight(TextStyle style, FontWeight wanted) {
  final FontWeight? weight = faceSafeFontWeight(style.fontFamily, wanted);
  return weight == null ? style : style.copyWith(fontWeight: weight);
}
