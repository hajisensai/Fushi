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
  // 第 24 个手写形态：按行 `line.indexOf(...)` 截断到行尾。它错得很具体——把行内
  // 第一个斜杠对当注释起点，于是**字符串字面量里的 `https:` 双斜杠、`//host/path`
  // 被当成注释**，整行后半截被吃掉：要求型断言（isTrue）因此假红，禁止型断言
  // （isFalse）因此假绿。块注释同样一概放行。JS 语料还多一层：正则字面量里的
  // 转义斜杠也会被砍掉半行，必须走 maskJsComments。
  r"indexOf('//')": 'maskComments（JS 语料用 maskJsComments；CSS 用 maskCssComments）',
  r'indexOf("//")': 'maskComments（JS 语料用 maskJsComments）',
};
