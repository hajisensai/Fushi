/// 内置引擎 fast-resume 文件（libtorrent `write_resume_data_buf` 产出的 bencode
/// 字典，native `ht_save_resume_data` 落成 `<resumeDir>/<infohash>.resume`）里
/// 的 `save_path` 改写（BUG-3541）。
///
/// 为什么要改写：`ht_load_resume_dir` 用 `lt::read_resume_data` 原样读回 resume
/// 里记的**绝对** save_path。数据根迁移 / 沙箱重定位把默认下载根
/// `<documents>/anime_downloads/content` 连同文件一起搬走后，不改写的 resume
/// 会让种子指向已搬空的旧目录（续传从零开始、做种断）。
///
/// 只做字节级拼接：定位顶层字典里 `save_path` 的值区间、替换那一段，其余字节
/// 原样保留（不重新编码整份字典，libtorrent 的其它字段一个字节都不动）。
library;

import 'dart:convert';
import 'dart:typed_data';

/// resume 目录名（`<documents>/anime_downloads/<这个>`），app 侧派生内置引擎
/// resume 目录与数据根迁移改写 resume 时共用。
const String kEmbeddedTorrentFastResumeDirName = 'resume';

/// native `ht_save_resume_data` / `ht_load_resume_dir` 认的文件扩展名。
const String kEmbeddedTorrentFastResumeExtension = '.resume';

const int _d = 0x64; // 'd'
const int _e = 0x65; // 'e'
const int _i = 0x69; // 'i'
const int _l = 0x6c; // 'l'
const int _colon = 0x3a; // ':'
const int _zero = 0x30;
const int _nine = 0x39;

/// 读出 fast-resume 字节里顶层 `save_path`；不是合法 resume 字典或没有该键
/// 返回 null。
String? readFastResumeSavePath(Uint8List bytes) {
  final _SavePathSpan? span = _findSavePath(bytes);
  if (span == null) return null;
  return span.value;
}

/// 按 [rebase] 改写 fast-resume 字节里顶层 `save_path`。
///
/// 返回改写后的新字节；以下情况返回 null（调用方不写盘）：
/// - 不是合法的 bencode 字典 / 没有 `save_path` / 值不是 UTF-8 字符串；
/// - [rebase] 返回原值（作用域外路径，如用户自选的外部下载根）。
Uint8List? rebaseFastResumeSavePath(
  Uint8List bytes,
  String Function(String savePath) rebase,
) {
  final _SavePathSpan? span = _findSavePath(bytes);
  if (span == null) return null;
  final String rebased = rebase(span.value);
  if (rebased == span.value) return null;
  final List<int> encoded = utf8.encode(rebased);
  final BytesBuilder out = BytesBuilder(copy: false)
    ..add(Uint8List.sublistView(bytes, 0, span.start))
    ..add(ascii.encode('${encoded.length}:'))
    ..add(encoded)
    ..add(Uint8List.sublistView(bytes, span.end));
  return out.toBytes();
}

class _SavePathSpan {
  const _SavePathSpan(this.start, this.end, this.value);

  /// 值（含 `<len>:` 前缀）在原字节里的 [start, end) 区间。
  final int start;
  final int end;
  final String value;
}

_SavePathSpan? _findSavePath(Uint8List bytes) {
  try {
    if (bytes.isEmpty || bytes[0] != _d) return null;
    // 整份字典必须完整合法（顶层 `e` 恰好是最后一个字节）才改：截断 / 尾部带
    // 垃圾的文件 libtorrent 本来就加载不了，改写它只会把坏数据「修」成别的样子。
    if (_skipValue(bytes, 0) != bytes.length) return null;
    int pos = 1;
    while (bytes[pos] != _e) {
      final ({int start, int end, int next}) key = _readString(bytes, pos);
      final int valueStart = key.next;
      final int valueEnd = _skipValue(bytes, valueStart);
      if (_isSavePathKey(bytes, key.start, key.end)) {
        if (!_isDigit(bytes[valueStart])) return null;
        final ({int start, int end, int next}) value = _readString(
          bytes,
          valueStart,
        );
        final String decoded = utf8.decode(
          Uint8List.sublistView(bytes, value.start, value.end),
        );
        return _SavePathSpan(valueStart, valueEnd, decoded);
      }
      pos = valueEnd;
    }
    return null;
  } on FormatException {
    return null;
  } on RangeError {
    return null;
  }
}

const List<int> _savePathKey = <int>[
  0x73, 0x61, 0x76, 0x65, 0x5f, 0x70, 0x61, 0x74, 0x68, // save_path
];

bool _isSavePathKey(Uint8List bytes, int start, int end) {
  if (end - start != _savePathKey.length) return false;
  for (int k = 0; k < _savePathKey.length; k++) {
    if (bytes[start + k] != _savePathKey[k]) return false;
  }
  return true;
}

bool _isDigit(int byte) => byte >= _zero && byte <= _nine;

/// 读 `<len>:<bytes>`，返回内容区间与下一个位置。
({int start, int end, int next}) _readString(Uint8List bytes, int pos) {
  int length = 0;
  int cursor = pos;
  if (cursor >= bytes.length || !_isDigit(bytes[cursor])) {
    throw const FormatException('bencode string expected');
  }
  while (cursor < bytes.length && bytes[cursor] != _colon) {
    if (!_isDigit(bytes[cursor])) {
      throw const FormatException('bad bencode string length');
    }
    length = length * 10 + (bytes[cursor] - _zero);
    if (length > bytes.length) {
      throw const FormatException('bencode string overflows buffer');
    }
    cursor++;
  }
  if (cursor >= bytes.length) {
    throw const FormatException('unterminated bencode string length');
  }
  final int start = cursor + 1;
  final int end = start + length;
  if (end > bytes.length) {
    throw const FormatException('bencode string overflows buffer');
  }
  return (start: start, end: end, next: end);
}

/// 跳过 [pos] 处的一个值，返回它之后的位置。
int _skipValue(Uint8List bytes, int pos) {
  if (pos >= bytes.length) {
    throw const FormatException('bencode value expected');
  }
  final int tag = bytes[pos];
  if (_isDigit(tag)) return _readString(bytes, pos).next;
  if (tag == _i) {
    int cursor = pos + 1;
    while (cursor < bytes.length && bytes[cursor] != _e) {
      cursor++;
    }
    if (cursor >= bytes.length) {
      throw const FormatException('unterminated bencode integer');
    }
    return cursor + 1;
  }
  if (tag == _l) {
    int cursor = pos + 1;
    while (true) {
      if (cursor >= bytes.length) {
        throw const FormatException('unterminated bencode list');
      }
      if (bytes[cursor] == _e) return cursor + 1;
      cursor = _skipValue(bytes, cursor);
    }
  }
  if (tag == _d) {
    int cursor = pos + 1;
    while (true) {
      if (cursor >= bytes.length) {
        throw const FormatException('unterminated bencode dict');
      }
      if (bytes[cursor] == _e) return cursor + 1;
      cursor = _readString(bytes, cursor).next;
      cursor = _skipValue(bytes, cursor);
    }
  }
  throw const FormatException('unknown bencode tag');
}
