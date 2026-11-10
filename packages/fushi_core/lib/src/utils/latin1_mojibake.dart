import 'dart:convert';
import 'dart:typed_data';

/// 剥掉「UTF-8 字节被当成 Latin-1 解码」造成的乱码层，返回剥到不能再剥时的
/// 字符串；本来就不是这种乱码的原样返回。
///
/// 来历（BUG-4243 / 反馈 hbIHtWi2Q7）：OneDrive / Dropbox 下载的聚合 JSON 曾按
/// Latin-1 解码，上传时又按 UTF-8 编码，每轮同步把非 ASCII 字符串（书名等）的每个
/// UTF-8 字节变成一个字符，长度翻倍。传输端已修，但已经落进本地库和各端云端聚合
/// 文件里的乱码行还在：一层乱码 = 字符串的每个码元都 ≤ 0xFF，把码元当字节按
/// **严格** UTF-8 解码能成功。逐层剥到解不开 / 不再变化为止。
///
/// 误判面：只有「全部码元 ≤ 0xFF、含非 ASCII、且这些字节恰好组成合法 UTF-8 多字节
/// 序列」的字符串会被改写（如字面量 `Ã©`）。正常的 Latin-1 文本（`Café`：`é` 单独
/// 一个 0xE9 不是合法 UTF-8）不受影响；含 > 0xFF 字符的文本（日文、中文）一字不动。
String unwrapLatin1Mojibake(final String input) {
  String current = input;
  while (true) {
    final String? next = _unwrapOnce(current);
    if (next == null) return current;
    current = next;
  }
}

/// [input] 是否带至少一层 Latin-1 乱码（[unwrapLatin1Mojibake] 会改写它）。
bool hasLatin1Mojibake(final String input) => _unwrapOnce(input) != null;

/// 剥一层；不是乱码返回 null。每剥一层长度严格变短（多字节序列折成一个字符），
/// 所以 [unwrapLatin1Mojibake] 的循环必然终止。
String? _unwrapOnce(final String s) {
  final int length = s.length;
  bool sawHigh = false;
  for (int i = 0; i < length; i++) {
    final int unit = s.codeUnitAt(i);
    if (unit > 0xFF) return null;
    if (unit >= 0x80) sawHigh = true;
  }
  if (!sawHigh) return null;
  final Uint8List bytes = Uint8List(length);
  for (int i = 0; i < length; i++) {
    bytes[i] = s.codeUnitAt(i);
  }
  try {
    return const Utf8Decoder().convert(bytes);
  } on FormatException {
    return null;
  }
}
