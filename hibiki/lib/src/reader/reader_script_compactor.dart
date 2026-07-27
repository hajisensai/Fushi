/// 注入前把阅读器 setup 脚本里的**整行注释和空行**剥掉。
///
/// 背景（实测）：每次跨章都要把整段 setup 脚本（selection + pagination shell + caret +
/// furigana + 手势，数百 KB）经 platform channel 传给 WebView 再由 JS 引擎解析执行，
/// 真机 `[chapter-perf] evalSetupScript` 中位数 25~40ms，且与章节体量无关——是纯固定
/// 开销。脚本源码里带着大量中文注释（它们是给人看的，对 JS 引擎毫无意义），跟着一起
/// 编组、传输、解析。剥掉后传的是同一份语义的脚本，只是没有注释和空行。
///
/// 只做**整行**剥离，绝不碰行内内容：
/// - `trim()` 后以 `//` 开头的整行 → 删（行内尾注释保留，避免误伤 `'https://…'`、
///   正则字面量 `/[^/]+/` 这类合法代码里的 `//`）。
/// - 空行/纯空白行 → 删。
/// - 模板字符串（反引号）内部的行**原样保留**——那里的 `//` 和空行是数据不是注释。
///   用未转义反引号计数跟踪模板态（脚本里的模板字符串都是单层、无嵌套模板）。
/// - 块注释 `/* … */` 不处理（跨行状态机在有正则/字符串的语料上容易误判，收益也小）。
class ReaderScriptCompactor {
  ReaderScriptCompactor._();

  /// 返回剥离整行注释与空行后的等价脚本。行内容不做任何改写。
  static String compact(String js) {
    final List<String> out = <String>[];
    bool inTemplate = false;
    for (final String line in js.split('\n')) {
      if (!inTemplate) {
        final String trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('//')) {
          inTemplate = _toggleTemplate(inTemplate, line);
          continue;
        }
      }
      out.add(line);
      inTemplate = _toggleTemplate(inTemplate, line);
    }
    return out.join('\n');
  }

  /// 按本行未转义反引号的个数翻转模板字符串状态（奇数个 = 状态翻转）。
  static bool _toggleTemplate(bool inTemplate, String line) {
    bool state = inTemplate;
    for (int i = 0; i < line.length; i++) {
      if (line.codeUnitAt(i) != 0x60) continue; // '`'
      int backslashes = 0;
      int j = i - 1;
      while (j >= 0 && line.codeUnitAt(j) == 0x5C) {
        backslashes++;
        j--;
      }
      if (backslashes.isEven) state = !state;
    }
    return state;
  }
}
