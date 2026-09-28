// 跨用户作品匹配键 WorkRef（设计 §3.3；服务端解析见 services/leaderboard/src/shelf.js）。
//
// 一个条目上报一组键，按优先级 bgm → isbn → vndb → tmdb → anidb → src → t，每个命名空间
// 至多一个。服务端任一键命中已有作品即归入同一 work，所以弱键 `t:`（标题|作者）
// 的归一化必须对「同一本书的常见写法差异」稳定，又不能把不同作品压成同一个键。

/// 服务端 REF_RE：`<ns>:<body>`，body 为 1–256 个 UTF-16 码元且不含 U+0000–U+001F。
const int _maxRefBody = 256;

/// `t:` 键里标题与作者各自的码元上限（合计 + 分隔符不超过 [_maxRefBody]）。
const int _maxTitleKey = 170;
const int _maxAuthorKey = 80;

final RegExp _controlChars = RegExp(r'[\u0000-\u001f\u007f]');
final RegExp _whitespace = RegExp(r'\s+', unicode: true);

/// 末尾的文库名括号（`（角川文庫）` / `(電撃文庫)`，全角括号已先转半角）与 `【…】` 标注。
final RegExp _trailingBunko = RegExp(r'\([^()]*文庫\)\s*$');
final RegExp _trailingLenticular = RegExp(r'【[^【】]*】\s*$');

/// 全角 ASCII（U+FF01–U+FF5E）→ 半角，全角空格 U+3000 → 空格。
///
/// 这是 NFKC 在书名场景里最常见的一部分，**不是**完整 NFKC：半角片假名不合成全角、
/// 丸数字 / 罗马数字 / 合字等兼容字符不展开（仓库没有 Unicode 规范化库，服务端也只做 NFC）。
String _foldFullwidthAscii(String s) {
  final StringBuffer out = StringBuffer();
  for (final int c in s.runes) {
    if (c >= 0xff01 && c <= 0xff5e) {
      out.writeCharCode(c - 0xfee0);
    } else if (c == 0x3000) {
      out.writeCharCode(0x20);
    } else {
      out.writeCharCode(c);
    }
  }
  return out.toString();
}

/// 截到至多 [maxUnits] 个 UTF-16 码元，不劈开代理对。
String _clipUnits(String s, int maxUnits) {
  if (s.length <= maxUnits) return s;
  int end = maxUnits;
  final int last = s.codeUnitAt(end - 1);
  if (last >= 0xd800 && last <= 0xdbff) end--;
  return s.substring(0, end);
}

/// 标题 / 作者的匹配用归一化：全角 ASCII 转半角、去掉末尾的「（…文庫）」「(…文庫)」「【…】」
/// 后缀（可叠加多层）、小写、删除全部空白与控制字符。
String normalizeWorkTitleKey(String s) {
  String t = _foldFullwidthAscii(s).replaceAll(_controlChars, ' ').trim();
  while (true) {
    final String next = t
        .replaceFirst(_trailingBunko, '')
        .replaceFirst(_trailingLenticular, '')
        .trim();
    // 整个标题就是括号（如「【完全版】」）时保留原样，别把标题剥成空。
    if (next == t || next.isEmpty) break;
    t = next;
  }
  return t.toLowerCase().replaceAll(_whitespace, '');
}

/// ISBN-10 / ISBN-13（可带 `urn:isbn:` / `ISBN` 前缀、连字符、空格、全角数字）→ 13 位 ISBN。
/// 校验位不对、长度不对或 13 位不是 978/979 开头时返回 null。
String? normalizeIsbn13(String raw) {
  String s = _foldFullwidthAscii(raw).trim().toLowerCase();
  s = s.replaceFirst(RegExp(r'^(urn:)?isbn(-1[03])?:?'), '');
  s = s.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();
  if (RegExp(r'^\d{13}$').hasMatch(s)) {
    if (!s.startsWith('978') && !s.startsWith('979')) return null;
    return _isbn13CheckDigit(s.substring(0, 12)) == s[12] ? s : null;
  }
  if (RegExp(r'^\d{9}[\dX]$').hasMatch(s)) {
    int sum = 0;
    for (int i = 0; i < 10; i++) {
      final int d = s[i] == 'X' ? 10 : int.parse(s[i]);
      sum += (10 - i) * d;
    }
    if (sum % 11 != 0) return null;
    final String body = '978${s.substring(0, 9)}';
    return '$body${_isbn13CheckDigit(body)}';
  }
  return null;
}

String _isbn13CheckDigit(String first12) {
  int sum = 0;
  for (int i = 0; i < 12; i++) {
    sum += int.parse(first12[i]) * (i.isEven ? 1 : 3);
  }
  return '${(10 - sum % 10) % 10}';
}

/// `<ns>:<body>`；body 空、超长或含控制字符（服务端必 400）时返回 null。
String? _ref(String ns, String? body) {
  final String v = (body ?? '').trim();
  if (v.isEmpty || v.length > _maxRefBody || _controlChars.hasMatch(v)) {
    return null;
  }
  return '$ns:$v';
}

/// 按优先级 bgm → isbn → vndb → tmdb → anidb → src → t 组装匹配键，每命名空间至多一个。
///
/// - [isbn] 经 [normalizeIsbn13]，不合法的直接丢弃（错 ISBN 会把书并到别人的作品上）；
/// - [vndbId] 接受 `v123` 或 `123`，统一成 `v123`；
/// - [tmdbRef] 形如 `tv:123` / `movie:456`，原样使用；
/// - `t:<norm(title)>|<norm(author)>`：标题归一化后为空则不产出。
List<String> buildWorkRefs({
  String? bgmSubjectId,
  String? isbn,
  String? vndbId,
  String? tmdbRef,
  String? anidbAid,
  String? sourceRef,
  required String title,
  String author = '',
}) {
  final String? vndb = vndbId?.trim().toLowerCase();
  final String titleKey = _clipUnits(
    normalizeWorkTitleKey(title),
    _maxTitleKey,
  );
  final String authorKey = _clipUnits(
    normalizeWorkTitleKey(author),
    _maxAuthorKey,
  );
  return <String?>[
    _ref('bgm', bgmSubjectId),
    _ref('isbn', isbn == null ? null : normalizeIsbn13(isbn)),
    _ref(
      'vndb',
      vndb == null || vndb.isEmpty
          ? null
          : (vndb.startsWith('v') ? vndb : 'v$vndb'),
    ),
    _ref('tmdb', tmdbRef),
    _ref('anidb', anidbAid),
    _ref('src', sourceRef),
    titleKey.isEmpty ? null : _ref('t', '$titleKey|$authorKey'),
  ].whereType<String>().toList(growable: false);
}
