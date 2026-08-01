/// Anki 卡模板渲染（mustache 子集）——**给编辑器预览用**。
///
/// 为什么需要它：预览过去是一份手写的 DOM mock，只是「长得像」Lapis。用户换了
/// Lapis 版本、或自己改过模板，预览就和真卡对不上（反馈原话「调整器里面默认的
/// lapis 和默认的 lapis 不一样」）。改成拿**用户自己的模板**渲染示例数据之后，
/// 预览的结构天然与真卡一致，不再有「mock 与模板漂开」这一整类问题。
///
/// 只实现 Anki 模板语法里预览用得到的那部分，且**只用于渲染示例数据、不参与
/// 任何写入**：
/// * `{{Field}}` 变量替换
/// * `{{#Field}}…{{/Field}}` 非空段、`{{^Field}}…{{/Field}}` 空段
/// * `{{filter:Field}}` 过滤器前缀（furigana / kana / text / kanji / cloze …）
///   ——预览一律按「取字段原值」处理；示例数据本来就是给人看形状的，逐个实现
///   过滤器的真实语义只会引入与 Anki 的新分歧。
/// * 未知字段渲染成空串（与 Anki 一致：模板引用不存在的字段就是空）
///
/// 刻意**不实现** `{{FrontSide}}`（背面预览不嵌正面）与条件嵌套之外的任何扩展。
library;

/// 一段模板里被引用到的全部字段名（含过滤器前缀的取字段名后的结果）。
///
/// 用途：让预览知道「这份模板到底会用到哪些字段」，从而只为它们准备示例值。
Set<String> ankiTemplateReferencedFields(String template) {
  final Set<String> names = <String>{};
  for (final RegExpMatch m in _tagPattern.allMatches(template)) {
    final String raw = m.group(1)!.trim();
    if (raw.isEmpty) continue;
    final String body =
        raw.startsWith('#') || raw.startsWith('^') || raw.startsWith('/')
            ? raw.substring(1).trim()
            : raw;
    final String field = _stripFilters(body);
    if (field.isNotEmpty && field != 'FrontSide') names.add(field);
  }
  return names;
}

/// 渲染 [template]，用 [fields] 取值；缺失字段按空串处理。
///
/// 解析是单遍扫描 + 段栈：段内容是否输出由栈顶决定，所以嵌套段、以及「段内还有
/// 变量」都自然成立。标签不配对（用户模板写坏了）时按「当作普通文本」处理而不是
/// 抛错——预览的职责是尽量把他的卡画出来，不是校验他的模板。
String renderAnkiTemplate(String template, Map<String, String> fields) {
  final StringBuffer out = StringBuffer();
  // 每一层记录「这一层是否应当输出」。栈底恒 true。
  final List<bool> emit = <bool>[true];
  bool visible() => emit.every((bool e) => e);

  int cursor = 0;
  for (final RegExpMatch m in _tagPattern.allMatches(template)) {
    if (visible()) out.write(template.substring(cursor, m.start));
    cursor = m.end;
    final String raw = m.group(1)!.trim();
    if (raw.isEmpty) continue;

    if (raw.startsWith('#') || raw.startsWith('^')) {
      final bool inverted = raw.startsWith('^');
      final String field = _stripFilters(raw.substring(1).trim());
      final bool has = (fields[field] ?? '').trim().isNotEmpty;
      emit.add(inverted ? !has : has);
      continue;
    }
    if (raw.startsWith('/')) {
      if (emit.length > 1) emit.removeLast();
      continue;
    }
    if (!visible()) continue;
    final String field = _stripFilters(raw);
    if (field == 'FrontSide') continue;
    out.write(fields[field] ?? '');
  }
  if (visible()) out.write(template.substring(cursor));
  return out.toString();
}

/// `{{ … }}`。非贪婪，且不跨越 `}}`。
final RegExp _tagPattern = RegExp(r'\{\{(.*?)\}\}', dotAll: true);

/// 去掉 `filter:` 前缀链（`{{furigana:kana:Field}}` → `Field`）。
String _stripFilters(String body) {
  final int last = body.lastIndexOf(':');
  return (last < 0 ? body : body.substring(last + 1)).trim();
}
