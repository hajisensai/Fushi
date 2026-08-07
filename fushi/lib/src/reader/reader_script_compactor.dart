/// 注入前把阅读器 setup 脚本里的**整行注释和空行**剥掉。
///
/// 背景（实测）：每次跨章都要把整段 setup 脚本（selection + pagination shell + caret +
/// furigana + 手势，数百 KB）经 platform channel 传给 WebView 再由 JS 引擎解析执行，
/// 真机 `[chapter-perf] evalSetupScript` 中位数 25~40ms，且与章节体量无关——是纯固定
/// 开销。脚本源码里带着大量中文注释（它们是给人看的，对 JS 引擎毫无意义），跟着一起
/// 编组、传输、解析。剥掉后传的是同一份语义的脚本，只是没有注释和空行。
///
/// 只做**整行**剥离，绝不碰行内内容：
/// - 行首词法状态处于**代码区**（不在模板串、不在块注释）且 `trim()` 后为空或以 `//`
///   开头的整行 → 删。行内尾注释保留（避免误伤 `'https://…'`、正则字面量 `/[^/]+/`
///   这类合法代码里的 `//`）。
/// - 模板字符串（反引号）内部的行**原样保留**——那里的 `//` 和空行是数据不是注释。
/// - 块注释 `/* … */` 内部的行也原样保留：体量极小，不值得冒「`*/` 后同行还有代码」的险。
///
/// 词法状态怎么算（根因修复）：旧实现按「本行未转义反引号的奇偶」翻转模板态，把写在
/// **注释里、引号串里、正则里**的反引号也算进去——任何人在 JS 注释里写一个反引号，就会
/// 把后续真模板串的内部当成代码区，把模板里的空行/数据行剥掉，CI 全绿而线上白屏。现在
/// 改成真正的单遍词法扫描（[_JsLexer]）：行注释、块注释、单/双引号串、模板串（含 `${}`
/// 嵌套）、正则字面量各自成状态，反引号只有出现在代码区才计数。那个地雷从根上不存在了。
class ReaderScriptCompactor {
  ReaderScriptCompactor._();

  /// 返回剥离整行注释与空行后的等价脚本。行内容不做任何改写。
  static String compact(String js) {
    final List<String> out = <String>[];
    final _JsLexer lexer = _JsLexer();
    for (final String line in js.split('\n')) {
      if (lexer.atCode) {
        final String trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('//')) {
          lexer.scanLine(line);
          continue;
        }
      }
      out.add(line);
      lexer.scanLine(line);
    }
    return out.join('\n');
  }

  /// 扫完整份脚本后词法状态是否回到干净顶层（不在模板串 / 块注释 / `${}` 内）。
  ///
  /// 这是给**守卫测试**用的自检：真实注入脚本都是完整的 IIFE，扫完必然干净。一旦某次
  /// 编辑把扫描器带跑偏（比如写出扫描器读不懂的正则/字符串），这里会转假、守卫测试转红
  /// ——而不是静默地产出一份坏脚本。
  static bool scansCleanly(String js) {
    final _JsLexer lexer = _JsLexer();
    for (final String line in js.split('\n')) {
      lexer.scanLine(line);
    }
    return lexer.isClean;
  }
}

/// 一个词法上下文：要么是模板字符串体，要么是代码区（顶层，或模板 `${}` 内）。
class _JsContext {
  _JsContext({required this.isTemplate});

  final bool isTemplate;

  /// 代码区内未闭合的 `{` 数。为 0 时遇到 `}` 就是 `${}` 的收口。
  int braceDepth = 0;
}

/// 单遍扫描的 JS 词法状态机。只回答一个问题：每一行的**行首**处于什么状态。
class _JsLexer {
  final List<_JsContext> _stack = <_JsContext>[_JsContext(isTemplate: false)];

  bool _inBlockComment = false;

  /// 上一个有效（非空白、非注释）字符，用于区分 `/` 是除号还是正则开头。
  int _prevSignificant = -1;

  /// 紧贴 [_prevSignificant] 结尾的标识符（用于 `return /re/` 这类关键字后的正则）。
  String _prevWord = '';

  /// 这些关键字后面的 `/` 是正则而不是除号（它们以标识符字符结尾，但后面跟表达式）。
  static const Set<String> _regexPrefixKeywords = <String>{
    'return',
    'typeof',
    'instanceof',
    'in',
    'of',
    'new',
    'delete',
    'void',
    'case',
    'do',
    'else',
    'yield',
    'await',
    'throw',
  };

  /// 行首是否处于代码区（可以按「整行注释/空行」剥掉本行）。
  bool get atCode => !_inBlockComment && !_stack.last.isTemplate;

  /// 扫完全文后是否回到干净顶层。
  bool get isClean =>
      !_inBlockComment && _stack.length == 1 && !_stack.first.isTemplate;

  void scanLine(String line) {
    final int n = line.length;
    int i = 0;
    while (i < n) {
      if (_inBlockComment) {
        i = _consumeBlockComment(line, i);
        continue;
      }
      if (_stack.last.isTemplate) {
        i = _consumeTemplate(line, i);
        continue;
      }
      final int next = _consumeCode(line, i);
      // 负数 = 行注释或行内未闭合字符串：本行剩余不再影响跨行状态。
      if (next < 0) return;
      i = next;
    }
  }

  int _consumeBlockComment(String line, int i) {
    if (line.codeUnitAt(i) == 0x2A && _peek(line, i + 1) == 0x2F) {
      _inBlockComment = false;
      return i + 2;
    }
    return i + 1;
  }

  int _consumeTemplate(String line, int i) {
    final int c = line.codeUnitAt(i);
    if (c == 0x5C) return i + 2; // 反斜杠转义，下一字符不计数
    if (c == 0x60) {
      _stack.removeLast(); // 反引号收口
      _note(c); // 模板串之后的 `/` 是除号，不是正则
      return i + 1;
    }
    if (c == 0x24 && _peek(line, i + 1) == 0x7B) {
      _stack.add(_JsContext(isTemplate: false)); // ${ 进入嵌套代码区
      _note(0x7B); // 嵌套代码区开头是表达式位置
      return i + 2;
    }
    return i + 1;
  }

  /// 处理代码区的一个字符，返回下一个下标；返回负数 = 本行到此为止。
  int _consumeCode(String line, int i) {
    final int c = line.codeUnitAt(i);
    if (c == 0x2F) return _consumeSlash(line, i); // '/'
    if (c == 0x27 || c == 0x22) {
      // 单/双引号串不能裸跨行（跨行就是语法错），行内未闭合就当它到行尾为止。
      final int end = _skipQuoted(line, i, c);
      _note(c);
      return end < 0 ? -1 : end;
    }
    if (c == 0x60) {
      _stack.add(_JsContext(isTemplate: true));
      _note(c);
      return i + 1;
    }
    if (c == 0x7B) {
      _stack.last.braceDepth++;
      _note(c);
      return i + 1;
    }
    if (c == 0x7D) {
      final _JsContext ctx = _stack.last;
      if (ctx.braceDepth > 0) {
        ctx.braceDepth--;
      } else if (_stack.length > 1) {
        _stack.removeLast(); // `${…}` 收口，回到模板串
      }
      _note(c);
      return i + 1;
    }
    _note(c);
    return i + 1;
  }

  int _consumeSlash(String line, int i) {
    final int next = _peek(line, i + 1);
    if (next == 0x2F) return -1; // // 行注释：本行剩余全是注释
    if (next == 0x2A) {
      _inBlockComment = true;
      return i + 2;
    }
    if (_regexAllowed) {
      final int end = _skipRegex(line, i);
      if (end >= 0) {
        _prevSignificant = 0x2F;
        _prevWord = '';
        return end;
      }
    }
    _note(0x2F); // 除号
    return i + 1;
  }

  /// `/` 开头能否是正则字面量（标准启发式：看前一个有效字符）。
  bool get _regexAllowed {
    if (_prevSignificant < 0) return true; // 脚本开头
    if (_isIdentifierChar(_prevSignificant)) {
      return _regexPrefixKeywords.contains(_prevWord);
    }
    // 标识符/数字/`)`/`]`/字符串字面量后的 `/` 是除法；其余标点
    // （= ( , : ; { } ! & | ? 等）后是正则。宁可当除号：误当成正则会把
    // 后面真实的引号/反引号吞进去，误当成除号顶多多扫几个字符。
    const Set<int> divisionAfter = <int>{
      0x29, // )
      0x5D, // ]
      0x27, // '
      0x22, // "
      0x60, // `
    };
    return !divisionAfter.contains(_prevSignificant);
  }

  /// 跳过一个正则字面量（含字符类 `[…]` 与转义），返回标志位之后的下标；未闭合返回 -1。
  int _skipRegex(String line, int start) {
    final int n = line.length;
    int j = start + 1;
    bool inClass = false;
    bool closed = false;
    while (j < n) {
      final int c = line.codeUnitAt(j);
      if (c == 0x5C) {
        j += 2;
        continue;
      }
      if (inClass) {
        if (c == 0x5D) inClass = false;
        j++;
        continue;
      }
      if (c == 0x5B) {
        inClass = true;
        j++;
        continue;
      }
      if (c == 0x2F) {
        closed = true;
        j++;
        break;
      }
      j++;
    }
    if (!closed) return -1;
    while (j < n && _isIdentifierChar(line.codeUnitAt(j))) {
      j++;
    }
    return j;
  }

  /// 跳过单/双引号字符串，返回闭引号之后的下标；行内未闭合返回 -1。
  int _skipQuoted(String line, int start, int quote) {
    final int n = line.length;
    int j = start + 1;
    while (j < n) {
      final int c = line.codeUnitAt(j);
      if (c == 0x5C) {
        j += 2;
        continue;
      }
      if (c == quote) return j + 1;
      j++;
    }
    return -1;
  }

  void _note(int c) {
    if (c == 0x20 || c == 0x09 || c == 0x0D) return; // 空白不算有效字符
    _prevSignificant = c;
    _prevWord =
        _isIdentifierChar(c) ? '$_prevWord${String.fromCharCode(c)}' : '';
  }

  static int _peek(String line, int i) =>
      i < line.length ? line.codeUnitAt(i) : -1;

  static bool _isIdentifierChar(int c) =>
      (c >= 0x61 && c <= 0x7A) || // a-z
      (c >= 0x41 && c <= 0x5A) || // A-Z
      (c >= 0x30 && c <= 0x39) || // 0-9
      c == 0x5F || // _
      c == 0x24; // $
}
