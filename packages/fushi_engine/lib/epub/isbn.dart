/// ISBN 规范化的**唯一口径**（schema v114 `epub_books.isbn`，排行榜作品匹配）。
///
/// 输入是 OPF `dc:identifier` 的原文或用户输入：容忍 `urn:isbn:` / `ISBN` /
/// `ISBN-13:` 前缀、连字符与空白；只接受校验位正确的 ISBN-10 或 978/979 开头的
/// ISBN-13；一律输出 13 位纯数字。不合法返回 null（绝不「猜」一个 ISBN——错误
/// 的强 ID 会把两部不同作品并成一个）。
library;

final RegExp _isbnPrefix = RegExp(r'^(?:urn:)?isbn(?:-1[03])?[\s:]*');
final RegExp _separators = RegExp(r'[\s\-]');
final RegExp _isbn13Shape = RegExp(r'^97[89]\d{10}$');
final RegExp _isbn10Shape = RegExp(r'^\d{9}[\dx]$');

/// 把 [raw] 规范化成 ISBN-13（13 位纯数字）；不是合法 ISBN 时返回 null。
String? normalizeIsbn13(String raw) {
  final String body = raw
      .trim()
      .toLowerCase()
      .replaceFirst(_isbnPrefix, '')
      .replaceAll(_separators, '');
  if (_isbn13Shape.hasMatch(body)) {
    return _ean13CheckDigit(body.substring(0, 12)) == body[12] ? body : null;
  }
  if (_isbn10Shape.hasMatch(body) && _isValidIsbn10(body)) {
    final String stem = '978${body.substring(0, 9)}';
    return '$stem${_ean13CheckDigit(stem)}';
  }
  return null;
}

/// 12 位数字的 EAN-13 校验位（权重 1,3 交替）。
String _ean13CheckDigit(String twelveDigits) {
  int sum = 0;
  for (int i = 0; i < 12; i++) {
    final int digit = twelveDigits.codeUnitAt(i) - 0x30;
    sum += i.isEven ? digit : digit * 3;
  }
  return '${(10 - sum % 10) % 10}';
}

/// ISBN-10 校验：Σ (10-i)·d_i ≡ 0 (mod 11)，末位 `x` = 10。
bool _isValidIsbn10(String tenChars) {
  int sum = 0;
  for (int i = 0; i < 10; i++) {
    final String ch = tenChars[i];
    final int value = ch == 'x' ? 10 : ch.codeUnitAt(0) - 0x30;
    sum += (10 - i) * value;
  }
  return sum % 11 == 0;
}
