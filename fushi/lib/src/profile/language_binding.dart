/// 语言级 Profile 绑定的**键归一化**——唯一真值源。
///
/// ## 为什么必须归一
///
/// 内容语言列（`EpubBooks.language` / `SrtBooks.language` / `VideoBooks.language`
/// / `Galgames.language`）存的是原始 BCP-47，同一种语言在库里可能以 `ja`、
/// `ja-JP`、`zh-Hans`、`zh-Hant-TW` 等多种形态出现（EPUB 的 `dc:language` 写什么
/// 就是什么，用户手填的更自由）。若绑定表直接拿原串当主键，用户绑了 `ja` 而书里
/// 写的是 `ja-JP`，绑定就**静默不生效**——没有报错、没有日志，只是「设了没用」。
/// 这正是最难归因的一类缺陷，所以写入与查询两侧都过这个函数，一处收敛。
///
/// ## 保留 script、丢弃 region
///
/// `zh-Hans` 与 `zh-Hant` 必须保持区分：词典和字体链都分简繁，把它们并成 `zh`
/// 会让两套配置塌成一套。而 region（`zh-CN` 的 `CN`、`ja-JP` 的 `JP`）对「用哪套
/// 词典 / 哪个 Anki 牌组」没有任何影响，保留它只会制造更多不相等的键。
library;

/// BCP-47 的「语言未确定」码。EPUB 的 `dc:language` 里确实会出现，语义上等同于
/// 「没标注」，因此与空串同等对待——绝不能让它变成一个所有未标注内容共用的
/// 伪语言键。
const String _kUndeterminedTag = 'und';

/// 把任意形态的语言标签归一成绑定键。
///
/// 规则：保留 `language`（小写）与可选的 `script`（首字母大写）子标签，丢弃
/// region / variant / extension。无法识别为合法语言标签时返回空串。
///
/// 返回空串 = 「语言未知」，调用方应当据此**跳过语言级绑定**（而不是拿空串去
/// 查表）。
///
/// - `ja` / `ja-JP` / `JA_jp` → `ja`
/// - `zh-Hant-TW` → `zh-Hant`
/// - `zh-CN` → `zh`
/// - `` / `   ` / `und` / `!!` → ``
String normalizeLanguageBinding(String? raw) {
  final String trimmed = raw?.trim() ?? '';
  if (trimmed.isEmpty) return '';

  // Java 风格的 `zh_Hans_CN` 与 BCP-47 的 `zh-Hans-CN` 视为同一形态：DB 列是
  // 自由文本，两种写法都可能被写进来。
  final List<String> parts = trimmed
      .replaceAll('_', '-')
      .split('-')
      .where((String s) => s.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '';

  final String language = parts.first.toLowerCase();
  if (!_isLanguageSubtag(language)) return '';
  if (language == _kUndeterminedTag) return '';

  for (final String part in parts.skip(1)) {
    if (_isScriptSubtag(part)) {
      return '$language-${_titleCase(part)}';
    }
  }
  return language;
}

/// 语言子标签：2–8 个字母（BCP-47 的 `language` 产生式；3 位的 ISO 639-3 与
/// 更长的注册码都落在这个区间内）。
bool _isLanguageSubtag(String s) =>
    s.length >= 2 && s.length <= 8 && _isAllAlpha(s);

/// 文字系统子标签：恰好 4 个字母（`Hans` / `Hant` / `Latn` / `Kana`…）。
bool _isScriptSubtag(String s) => s.length == 4 && _isAllAlpha(s);

bool _isAllAlpha(String s) {
  for (int i = 0; i < s.length; i++) {
    final int c = s.codeUnitAt(i);
    final bool isAlpha = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
    if (!isAlpha) return false;
  }
  return true;
}

String _titleCase(String s) =>
    s[0].toUpperCase() + s.substring(1).toLowerCase();
