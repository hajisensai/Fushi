import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:xml/xml.dart';

/// 「合并段内换行」（拍板台 zCkIxtnwcV，源级开关、默认关）。
///
/// カクヨム等网文站把作者敲的**每一行**都存成一个 `<p>`（或用单个 `<br>`
/// 断行），作者在句子中间折行时，阅读器里一句话就被拆成好几行。本函数把这类
/// 句中折行接回去，规则：
///
/// - 空行（只有空白 / `<br>` 的段落、连续两个 `<br>`）一律保留，是段落分隔；
/// - 上一行以句末 / 收尾标点结束（`。！？」』）…―` 等，见 [_lineEnders]）时保留换行；
/// - 下一行以对话 / 括号开头（`「『（【` 等）或以全角空格缩进开头（日文新段落的
///   写法）时保留换行；
/// - 其余情况视为句中折行，接成一行；两侧都是拉丁字母 / 数字时补一个空格，
///   中日文直接相接。
///
/// 只接**纯文字行**：带插图、标题、表格等块级内容的段落不动。输入是宿主
/// `toXhtml` 的产物（XMLSerializer 输出，保证良构）；万一解析不了就记日志并原样
/// 返回——这是可选的排版增强，不能因此丢章节正文。
String mergeLnReaderSoftLineBreaks(String xhtml) {
  if (!xhtml.contains('<p') && !xhtml.contains('<br')) return xhtml;
  final XmlDocument document;
  try {
    document = XmlDocument.parse('<fushi-root>$xhtml</fushi-root>');
  } on XmlException catch (error, stack) {
    ErrorLogService.instance.log('LnReaderLineBreaks.parse', error, stack);
    return xhtml;
  }
  final XmlElement root = document.rootElement;
  _mergeWithin(root);
  return root.children.map((XmlNode node) => node.toXmlString()).join();
}

/// 句末 / 收尾字符：行尾是它们时保留换行。
const String _lineEnders = '。．.！？!?‼⁇⁈⁉」』）)】〕〉》〙〗］]｝}”’"\'…‥―—─～~♪♫☆★♡♥：:';

/// 行首是它们时保留换行：对话 / 括号开头、全角空格缩进、分隔符号。
const String _lineStarters = '「『（(【〔〈《〘〖［[｛{“‘"\'―—─…‥・※＊*◇◆□■○●☆★　';

/// 只含这些元素（及文字）的段落才算「纯文字行」，可以接。
const Set<String> _inlineElements = <String>{
  'a',
  'abbr',
  'b',
  'bdi',
  'bdo',
  'big',
  'br',
  'cite',
  'code',
  'del',
  'dfn',
  'em',
  'font',
  'i',
  'ins',
  'kbd',
  'mark',
  'q',
  'rb',
  'rp',
  'rt',
  'rtc',
  'ruby',
  's',
  'samp',
  'small',
  'span',
  'strike',
  'strong',
  'sub',
  'sup',
  'tt',
  'u',
  'var',
  'wbr',
};

/// 振假名读音不算正文：取行首 / 行尾字符时跳过。
const Set<String> _rubyAnnotations = <String>{'rt', 'rp'};

final RegExp _asciiWord = RegExp(r'[A-Za-z0-9]');

void _mergeWithin(XmlElement parent) {
  for (final XmlElement child in parent.childElements.toList()) {
    _mergeWithin(child);
  }
  _mergeBreaks(parent);
  _mergeParagraphs(parent);
}

String _local(XmlElement element) => element.name.local.toLowerCase();

bool _isElement(XmlNode node, String name) =>
    node is XmlElement && _local(node) == name;

bool _isLayoutWhitespace(XmlNode node) =>
    node is XmlText && node.value.trim().isEmpty && !node.value.contains('　');

/// 正文可见文字（不含 `<rt>` / `<rp>` 读音）。
String _visibleText(XmlNode node) {
  if (node is XmlText) return node.value;
  if (node is XmlCDATA) return node.value;
  if (node is XmlElement) {
    if (_rubyAnnotations.contains(_local(node))) return '';
    return node.children.map(_visibleText).join();
  }
  return '';
}

bool _isInlineOnly(XmlElement element) {
  for (final XmlElement child in element.descendantElements) {
    if (!_inlineElements.contains(_local(child))) return false;
  }
  return true;
}

/// 行尾最后一个可见字符（去掉排版空白与全角空格）；空行返回 null。
String? _lastChar(String text) {
  final String trimmed = text.trimRight();
  if (trimmed.isEmpty) return null;
  return String.fromCharCode(trimmed.runes.last);
}

/// 行首第一个字符：只去掉排版空白（换行 / 半角空格），**保留**全角空格缩进。
String? _firstChar(String text) {
  final String trimmed = text.replaceFirst(RegExp(r'^[ \t\r\n\f]+'), '');
  if (trimmed.trim().isEmpty) return null;
  return String.fromCharCode(trimmed.runes.first);
}

/// 两行之间该不该接；该接时返回接缝（`''` 或拉丁文的一个空格），否则 null。
String? _joinSeparator(String? previousLast, String? nextFirst) {
  if (previousLast == null || nextFirst == null) return null;
  if (_lineEnders.contains(previousLast)) return null;
  if (_lineStarters.contains(nextFirst)) return null;
  final bool latin =
      _asciiWord.hasMatch(nextFirst) &&
      (_asciiWord.hasMatch(previousLast) || ',;'.contains(previousLast));
  return latin ? ' ' : '';
}

/// 同一父元素里的单个 `<br>`：两侧都是纯文字、且判为句中折行时去掉。
void _mergeBreaks(XmlElement parent) {
  final List<XmlNode> children = parent.children.toList();
  for (int i = 0; i < children.length; i++) {
    final XmlNode node = children[i];
    if (!_isElement(node, 'br')) continue;
    int before = i - 1;
    while (before >= 0 && _isLayoutWhitespace(children[before])) {
      before--;
    }
    int after = i + 1;
    while (after < children.length && _isLayoutWhitespace(children[after])) {
      after++;
    }
    if (before < 0 || after >= children.length) continue;
    final XmlNode previous = children[before];
    final XmlNode next = children[after];
    if (!_isInlineText(previous) || !_isInlineText(next)) continue;
    final String? separator = _joinSeparator(
      _lastChar(_lineTextBefore(children, before)),
      _firstChar(_visibleText(next)),
    );
    if (separator == null) continue;
    for (int k = before + 1; k < after; k++) {
      children[k].remove();
    }
    _trimEdge(previous, trailing: true);
    _trimEdge(next, trailing: false);
    if (separator.isNotEmpty) {
      next.parent!.children.insert(
        next.parent!.children.indexOf(next),
        XmlText(separator),
      );
    }
  }
}

/// 文字或不含 `<br>` 的行内元素（含 `<br>` 的元素自己内部已处理过）。
bool _isInlineText(XmlNode node) {
  if (node is XmlText || node is XmlCDATA) return true;
  if (node is! XmlElement) return false;
  final String name = _local(node);
  return name != 'br' &&
      _inlineElements.contains(name) &&
      _isInlineOnly(node) &&
      !node.descendantElements.any((XmlElement e) => _local(e) == 'br');
}

/// 第 [index] 个节点所在那一行的文字：往前拼到上一个 `<br>` 或开头为止，
/// 这样 `…<em>強調</em>\n` 这类行尾是空白文字的也能取到真正的行尾字符。
String _lineTextBefore(List<XmlNode> children, int index) {
  final List<String> parts = <String>[];
  for (int k = index; k >= 0; k--) {
    final XmlNode node = children[k];
    if (_isElement(node, 'br')) break;
    parts.add(_visibleText(node));
  }
  return parts.reversed.join();
}

/// 相邻兄弟 `<p>` 行：判为句中折行时把下一行的内容搬进上一行、删掉下一行。
void _mergeParagraphs(XmlElement parent) {
  XmlElement? current;
  final List<XmlNode> pendingWhitespace = <XmlNode>[];
  for (final XmlNode node in parent.children.toList()) {
    if (_isLayoutWhitespace(node)) {
      pendingWhitespace.add(node);
      continue;
    }
    final XmlElement? line = _textLine(node);
    if (line == null) {
      current = null;
      pendingWhitespace.clear();
      continue;
    }
    final XmlElement? target = current;
    final String? separator = target == null || line.attributes.isNotEmpty
        ? null
        : _joinSeparator(
            _lastChar(_visibleText(target)),
            _firstChar(_visibleText(line)),
          );
    if (target == null || separator == null) {
      current = line;
      pendingWhitespace.clear();
      continue;
    }
    for (final XmlNode whitespace in pendingWhitespace) {
      whitespace.remove();
    }
    pendingWhitespace.clear();
    if (target.children.isNotEmpty) {
      _trimEdge(target.children.last, trailing: true);
    }
    if (separator.isNotEmpty) target.children.add(XmlText(separator));
    final List<XmlNode> moved = line.children.toList();
    for (final XmlNode child in moved) {
      child.remove();
    }
    if (moved.isNotEmpty) _trimEdge(moved.first, trailing: false);
    target.children.addAll(moved);
    target.isSelfClosing = target.children.isEmpty;
    line.remove();
  }
}

/// 可接的「纯文字行」：非空、只含行内元素的 `<p>`。
XmlElement? _textLine(XmlNode node) {
  if (node is! XmlElement || _local(node) != 'p') return null;
  if (!_isInlineOnly(node)) return null;
  if (_visibleText(node).trim().isEmpty) return null;
  return node;
}

/// 去掉接缝处的排版空白（换行 / 缩进空格），免得在中日文之间渲染成空格。
/// 全角空格是正文，不动。
void _trimEdge(XmlNode node, {required bool trailing}) {
  XmlNode current = node;
  while (current is XmlElement && current.children.isNotEmpty) {
    current = trailing ? current.children.last : current.children.first;
  }
  if (current is! XmlText) return;
  current.value = trailing
      ? current.value.replaceFirst(RegExp(r'[ \t\r\n\f]+$'), '')
      : current.value.replaceFirst(RegExp(r'^[ \t\r\n\f]+'), '');
}
