/// 「手写注释剥离」的禁用形态表，供 `test/tools/source_guard_adoption_test.dart` 使用。
///
/// 为什么单独一个文件：这些 key 是**字面量模式**，放在守卫自己的源码里会被守卫自己
/// 扫到并判成违规（守卫的断言字面量同时也是守卫的输入）。把表挪出来后，守卫本体
/// 不再含任何禁用形态，于是**守卫自己也能被自己覆盖**——只有这一个模式表文件需要
/// 豁免，而它里面没有任何扫描逻辑可退化。
library;

/// 禁用形态 → 该改用哪个共享原语。
const Map<String, String> kBannedCommentStripPatterns = <String, String>{
  r"startsWith('//')": 'maskComments / containsCodeLine（JS 语料用 maskJsComments）',
  r'startsWith("//")': 'maskComments / containsCodeLine',
  r"replaceAll(RegExp(r'/\*": 'maskCssComments（等长掩码，别用删除式）',
  // PR#664 复核坐实的第 23 个手写形态：正则删除式只剥 // 行注释——块注释照样
  // 放行（锚点塞 /* */ 即假绿），且删除式改变下标。键取正则字面量本身：调用链
  // （source.replaceAll(...)）会被 dart format 折行，锚在单行稳定的部分。
  r"RegExp(r'//[^\n]*": 'maskComments（共享词法掩码，行+块注释一起掩）',
  r"replaceAll(RegExp(r'<!--": 'maskHtmlComments（等长掩码，别用删除式）',
};
