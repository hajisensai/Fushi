/// Lapis 卡片样式客制化的纯函数层：CSS 组合、字号缩放、漂移判定。
///
/// 设计（消除「覆盖用户改动」这个特殊情况）：推送到 Anki 的最终 styling 是
/// 三段拼接——vendored Lapis CSS + Hibiki delta（[LapisNoteType.template]，
/// 已有）+ **带标记的用户区段**（字号缩放变量覆写 + 用户自由 CSS）。用户客制化
/// 只存在于用户区段，基线升级时区段原样重拼，迁移不需要猜哪些是用户改的。
///
/// 全部纯函数，可单测；副作用（读写 Anki / 落盘备份）在 hibiki 应用层的
/// LapisTemplateService。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'lapis_note_type.dart';

/// 用户客制化区段起始标记。整段由 Hibiki 生成管理；用户在 Anki 里直接改
/// 标记内内容会在下次应用时被覆写（应用前有强制自动备份兜底）。
const String lapisUserCssBeginMarker = '/* HIBIKI-LAPIS-USER BEGIN */';

/// 用户客制化区段结束标记。
const String lapisUserCssEndMarker = '/* HIBIKI-LAPIS-USER END */';

/// 从 vendored Lapis CSS 里提取全部字号变量并按 [percent]（百分比，100 = 原样）
/// 缩放，产出一个 `:root` 覆写块。基准值直接解析自 [LapisNoteType.css]（单一
/// 真相源），vendored 版本升级后无需改这里。[percent] == 100 或未解析到任何变量
/// 时返回空串。
///
/// 上游 Lapis 的字号变量命名**不统一**：多数叫 `--pc-*-font-size` /
/// `--mobile-*-font-size`，但释义字号叫 `--pc-main-def-size` /
/// `--mobile-main-def-size`（没有 `font-` 中缀）。所以判据只是「以 `-size`
/// 结尾」（`[a-z-]*` already 吃掉 `font-`，不需要额外分组）——只认 `font-size`
/// 会静默漏掉释义字号，界面缩放对释义不生效，与「Scales every Lapis font size」
/// 的文案不符（本函数原始缺陷）。
/// 守卫见 `lapis_styling_test.dart`：断言 vendored CSS 里**每一个** px 取值的
/// `--pc-*` / `--mobile-*` 变量都被本函数覆盖，vendored 升级新增变量即打红。
///
/// **上游同步须留意的前瞻风险**：本函数 + 守卫一起把「`pc-`/`mobile-` 前缀 +
/// px 取值 == 字号」制度化了。上游若新增 `--pc-main-picture-size: 240px` 这类
/// **非字号**变量，正则会误伤把它一起缩放，守卫还会反过来强制要求它被纳入。
/// 同步 vendored Lapis 时必须人工过一遍新增的 `--pc-*` / `--mobile-*` px 变量：
/// 真是字号就放行，不是字号就得给本函数加排除表，别顺手把守卫改绿。
String buildLapisFontScaleCss(int percent) {
  if (percent == 100) return '';
  final RegExp pattern = RegExp(r'--((?:pc|mobile)-[a-z-]*size):\s*(\d+)px');
  final List<String> lines = <String>[];
  final Set<String> seen = <String>{};
  for (final RegExpMatch m in pattern.allMatches(LapisNoteType.css)) {
    final String name = m.group(1)!;
    if (!seen.add(name)) continue;
    final int base = int.parse(m.group(2)!);
    final int scaled = (base * percent / 100).round().clamp(1, 4096);
    lines.add('  --$name: ${scaled}px;');
  }
  if (lines.isEmpty) return '';
  return ':root {\n${lines.join('\n')}\n}';
}

/// 组合用户区段正文：字号缩放覆写 + 自由 CSS。两者皆空时返回空串
/// （= 不产出用户区段）。
String buildLapisUserSectionBody({
  required int fontScalePercent,
  required String customCss,
}) {
  final String scale = buildLapisFontScaleCss(fontScalePercent);
  final String custom = customCss.trim();
  if (scale.isEmpty && custom.isEmpty) return '';
  return <String>[
    if (scale.isNotEmpty) scale,
    if (custom.isNotEmpty) custom,
  ].join('\n\n');
}

/// 组合最终推送到 Anki 的完整 Lapis styling：
/// [LapisNoteType.template].css（vendored + Hibiki delta）+ 用户区段。
/// 无客制化时逐字节等于现行 `createModel` 落下的出厂 CSS（零破坏）。
String composeLapisCss({
  required int fontScalePercent,
  required String customCss,
}) {
  final String base = LapisNoteType.template.css;
  final String body = buildLapisUserSectionBody(
    fontScalePercent: fontScalePercent,
    customCss: customCss,
  );
  if (body.isEmpty) return base;
  return '$base\n$lapisUserCssBeginMarker\n$body\n$lapisUserCssEndMarker\n';
}

/// 从一份完整 styling 里提取用户区段正文（标记之间的内容，已 trim）。
/// 没有成对标记时返回 null——调用方（备份恢复）据此把 Hibiki 侧客制化状态
/// 清空，而不是猜。
String? extractLapisUserSectionBody(String css) {
  final int begin = css.indexOf(lapisUserCssBeginMarker);
  if (begin < 0) return null;
  final int bodyStart = begin + lapisUserCssBeginMarker.length;
  final int end = css.indexOf(lapisUserCssEndMarker, bodyStart);
  if (end < 0) return null;
  return css.substring(bodyStart, end).trim();
}

/// 比较用 CSS 规范化：统一换行 + 去首尾空白。Anki 端存取可能改变行尾/尾部
/// 空白，不做规范化会把等价内容误判成外来手改。
String normalizeCssForCompare(String css) =>
    css.replaceAll('\r\n', '\n').trim();

/// 规范化后 CSS 的 sha256（hex）。用作「上次应用的 styling」指纹持久化。
String lapisCssSha256(String css) =>
    sha256.convert(utf8.encode(normalizeCssForCompare(css))).toString();

/// 对 Anki 端现有 Lapis styling 的处置判定。
enum LapisStylingDecision {
  /// 与期望完全一致，无需动作。
  upToDate,

  /// 可安全覆写：Anki 端内容是 Hibiki 已知的自有产物（上次应用的指纹，或
  /// 从未被动过的出厂基线）。自动迁移只在此态下写入。
  safeUpdate,

  /// Anki 端内容来历不明（用户手改过）：自动迁移不得写入，只有用户显式
  /// 确认的「应用」可以（应用前强制自动备份）。
  foreignEdit,
}

/// 判定 Anki 端现有 [ankiCss] 相对期望 [expectedCss] 的处置方式。
///
/// [lastAppliedSha] 是 Hibiki 上次成功推送的 styling 指纹
/// （[lapisCssSha256]），null = 本机从未推送过。
LapisStylingDecision decideLapisStylingAction({
  required String ankiCss,
  required String expectedCss,
  required String? lastAppliedSha,
}) {
  final String anki = normalizeCssForCompare(ankiCss);
  if (anki == normalizeCssForCompare(expectedCss)) {
    return LapisStylingDecision.upToDate;
  }
  if (lastAppliedSha != null && lapisCssSha256(anki) == lastAppliedSha) {
    return LapisStylingDecision.safeUpdate;
  }
  // 出厂基线（用户从未动过）：纯 vendored CSS（上游原版 Lapis），或
  // vendored + Hibiki delta（现行 createModel 落下的出厂态）。
  final Set<String> pristine = <String>{
    normalizeCssForCompare(LapisNoteType.css),
    normalizeCssForCompare(LapisNoteType.template.css),
  };
  if (pristine.contains(anki)) return LapisStylingDecision.safeUpdate;
  return LapisStylingDecision.foreignEdit;
}
