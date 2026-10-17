/// 笔记字段里内联 `<style>` 的去重表示（「释义样式去重」，见设计文档同名一节）。
///
/// Yomitan 导出释义时每部词典都内联一份 `<style>`（几 KB 到几十 KB），同一部词典的每张卡都带
/// 同一份。存储层把够大的样式块换成指向共享媒体文件的一行引用：
///
/// ```html
/// <style>…css…</style>   ⇄   <link rel="stylesheet" href="_fushi_style_<sha1(css)>.css">
/// ```
///
/// - 文件名只由样式内容决定（sha1 of UTF-8），多台设备各自去重得到逐字节相同的字段值，
///   不会因此产生冲突；文件走现有的媒体同步（按内容哈希、只传对方没有的）。
/// - 下划线开头：Anki「检查媒体」不把它当未使用文件删除。
/// - 只换**没有任何属性**的 `<style>`…`</style>`（Yomitan 导出的就是这种形状），
///   `<script>` 里的文字不碰；样式短于 [kSrsStyleDedupMinChars] 不换（一个文件 + 一行引用不划算）。
///   因此 `srsExpandStyles(srsDedupStyles(x).html) == x` 逐字节成立（前提：x 本身没有手写的、
///   能解析到样式文件的规范引用行——那样的行会被一并展开）。
/// - 两种表示在合并语义里等价：[srsSameFieldText] 是修改记录比较「值是否相同」的口径
///   （见 field_edit.dart 的 `_sameValue`），去重前后、去重了一半的值互相比较都按展开后的内容判定。
///
/// [kSrsStyleDedupMinChars] 与引用行的写法属于持久化格式，**冻结**：改了会让不同版本对同一份内容
/// 算出不同的规范形。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 共享样式文件名前缀（下划线开头，Anki 检查媒体不删）。
const String kSrsStyleMediaPrefix = '_fushi_style_';

/// 去重门槛：样式正文（UTF-16 码元数）至少这么长才换成引用。冻结。
const int kSrsStyleDedupMinChars = 512;

const String _open = '<style>';
const String _close = '</style>';

final RegExp _scriptBlock = RegExp(
  r'<script\b[\s\S]*?</script\s*>',
  caseSensitive: false,
);

final RegExp _styleLink = RegExp(
  r'<link rel="stylesheet" href="(_fushi_style_[0-9a-f]{40}\.css)">',
);

/// 样式内容对应的共享文件名：`_fushi_style_<sha1>.css`。
String srsStyleMediaName(String css) =>
    '$kSrsStyleMediaPrefix${sha1.convert(utf8.encode(css))}.css';

/// 是不是共享样式文件名（形状判断，不校验内容）。
bool srsIsStyleMediaName(String name) =>
    RegExp(r'^_fushi_style_[0-9a-f]{40}\.css$').hasMatch(name);

/// 引用某个共享样式文件的那一行（规范写法，冻结）。
String srsStyleLinkTag(String name) => '<link rel="stylesheet" href="$name">';

/// 一次去重的结果。
class SrsStyleDedup {
  const SrsStyleDedup(this.html, this.styles);

  /// 换成引用之后的 HTML。
  final String html;

  /// 新引用到的样式：文件名 → 样式正文（落盘用）。
  final Map<String, String> styles;

  bool get changed => styles.isNotEmpty;
}

/// 对 [text] 的「`<script>` 之外」的片段逐段做 [transform]，`<script>` 块原样保留。
String _outsideScripts(String text, String Function(String chunk) transform) {
  final StringBuffer out = StringBuffer();
  int last = 0;
  for (final Match m in _scriptBlock.allMatches(text)) {
    out
      ..write(transform(text.substring(last, m.start)))
      ..write(m.group(0));
    last = m.end;
  }
  out.write(transform(text.substring(last)));
  return out.toString();
}

/// 把 [html] 里够大的无属性 `<style>` 块换成共享样式引用（纯函数，不碰磁盘）。
SrsStyleDedup srsDedupStyles(String html) {
  if (!html.contains(_open))
    return SrsStyleDedup(html, const <String, String>{});
  final Map<String, String> styles = <String, String>{};
  String chunkDedup(String chunk) {
    if (!chunk.contains(_open)) return chunk;
    final StringBuffer out = StringBuffer();
    int i = 0;
    while (true) {
      final int start = chunk.indexOf(_open, i);
      if (start < 0) break;
      final int bodyStart = start + _open.length;
      final int end = chunk.indexOf(_close, bodyStart);
      if (end < 0) break;
      final String css = chunk.substring(bodyStart, end);
      // 块里又出现一个 `<style>`（畸形 / 嵌套）：不动它，从下一个开头继续找。
      if (css.length < kSrsStyleDedupMinChars || css.contains(_open)) {
        out.write(chunk.substring(i, bodyStart));
        i = bodyStart;
        continue;
      }
      final String name = srsStyleMediaName(css);
      styles[name] = css;
      out
        ..write(chunk.substring(i, start))
        ..write(srsStyleLinkTag(name));
      i = end + _close.length;
    }
    out.write(chunk.substring(i));
    return out.toString();
  }

  final String out = _outsideScripts(html, chunkDedup);
  return SrsStyleDedup(styles.isEmpty ? html : out, styles);
}

/// [html]（`<script>` 之外）引用的共享样式文件名。
Set<String> srsStyleRefsIn(String html) {
  if (!html.contains(kSrsStyleMediaPrefix)) return const <String>{};
  final Set<String> out = <String>{};
  _outsideScripts(html, (String chunk) {
    for (final RegExpMatch m in _styleLink.allMatches(chunk)) {
      out.add(m.group(1)!);
    }
    return chunk;
  });
  return out;
}

/// 把共享样式引用展开回内联 `<style>`。[cssOf] 给出文件名对应的样式正文；给不出时
/// [dropMissing] = false 原样保留引用行（导出 / 回读：不丢信息），true 时删掉这一行
/// （卡面渲染：文件还没同步到时宁可暂时缺样式，也不让 WebView 去请求一个相对地址）。
String srsExpandStyles(
  String html,
  String? Function(String name) cssOf, {
  bool dropMissing = false,
}) {
  if (!html.contains(kSrsStyleMediaPrefix)) return html;
  return _outsideScripts(
    html,
    (String chunk) => chunk.replaceAllMapped(_styleLink, (Match m) {
      final String? css = cssOf(m.group(1)!);
      if (css == null) return dropMissing ? '' : m.group(0)!;
      return '$_open$css$_close';
    }),
  );
}

/// 两个字段文本按「去重规范形」是否相同：内联样式与它的引用行视为同一内容。
/// 修改记录合并（是否冲突 / 是否 no-op）用这个口径，见 field_edit.dart。
bool srsSameFieldText(String a, String b) {
  if (a == b) return true;
  if (!a.contains(_open) && !b.contains(_open)) return false;
  return srsDedupStyles(a).html == srsDedupStyles(b).html;
}
