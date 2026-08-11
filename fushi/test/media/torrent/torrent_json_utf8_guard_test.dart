// BUG-1522: libtorrent 的 error_code::message() 会走 Windows locale 的 ANSI
// code page，而同一份 payload 里的种子名/保存路径本来就是 UTF-8。
//
// 编码是**逐字段**的属性，不是整包的属性：没有任何单一 code page 能同时解对
// 两半。因此转换必须发生在 native 侧构造 JSON 的那一刻（那里才知道每个字段的
// 来源），Dart 侧只许原样按 UTF-8 读，不许做整包重解码——否则一个本地化错误
// 串就会把同包合法的种子名一起解成乱码。
//
// 下面两条守卫分别钉住这两半不变式。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 取出 `name(...)` 每次出现时括号里的实参文本（含定义处的形参列表）。
/// 只匹配带括号的出现，注释里裸提函数名不会污染结果。
Set<String> _argumentsOf(String source, String name) {
  final RegExp pattern = RegExp(
    '${RegExp.escape('$name(')}([^)]*)${RegExp.escape(')')}',
  );
  return pattern.allMatches(source).map((RegExpMatch m) => m.group(1)!).toSet();
}

void main() {
  test('native torrent JSON normalizes and sanitizes per field', () {
    final File bridge = File(
      '../native/fushi_torrent/fushi_torrent_ffi.cpp',
    );
    expect(bridge.existsSync(), isTrue);
    final String source = bridge.readAsStringSync();
    final int serializerAt = source.indexOf('void append_json_escaped(');
    final int nextHelperAt = source.indexOf(
      'void append_json_str_field(',
      serializerAt,
    );
    expect(serializerAt, greaterThanOrEqualTo(0));
    expect(nextHelperAt, greaterThan(serializerAt));
    final String serializer = source.substring(serializerAt, nextHelperAt);

    expect(serializer, contains('out += "\\\\ufffd"'));
    expect(serializer, contains('(continuation & 0xc0) != 0x80'));
    expect(serializer, contains('c == 0xed && second >= 0xa0'));
    expect(serializer, contains('c == 0xf4 && second >= 0x90'));
    expect(serializer, contains('out.append(*input, i, width)'));
    expect(source, contains('MultiByteToWideChar('));
    expect(source, contains('WideCharToMultiByte('));
    expect(source, contains('CP_ACP'));
    expect(source, contains('CP_UTF8'));
    expect(source, contains('LOCALE_IDEFAULTANSICODEPAGE'));
    expect(source, contains('GetLocaleInfoEx('));

    // ANSI 猜测只许发生在**单个字段**的入口，且只在这个字段本身不是合法
    // UTF-8 时；`append_json_escaped(std::string& out, const std::string& s)`
    // 的 `s` 就是那个字段。
    expect(serializer, contains('if (!is_valid_utf8(s))'));
    expect(serializer, contains('windows_ansi_to_utf8(s)'));

    // 真正要挡住的回归：把判断/转换从「一个字段」挪到「拼好的整包」（`out`，
    // 或任何已经拼接过的缓冲）。实参集合只允许「定义处的形参」和「单字段 s」
    // 两种，出现 windows_ansi_to_utf8(out) 之类立刻红。
    expect(
      _argumentsOf(source, 'windows_ansi_to_utf8'),
      <String>{'const std::string& s', 's'},
    );
    expect(
      _argumentsOf(source, 'is_valid_utf8'),
      <String>{'const std::string& s', 's'},
    );
  });

  test('the Dart side decodes the payload as UTF-8 without guessing', () {
    final File decoder = File(
      '../packages/fushi_torrent/lib/src/native_json.dart',
    );
    expect(decoder.existsSync(), isTrue);
    final String source = decoder.readAsStringSync();

    // 整包重解码所需的任何一件工具出现在这里，都意味着编码判断又漏回了
    // Dart 层——那一层看不见字段边界，只能全有全无地猜。
    for (final String forbidden in <String>[
      'MultiByteToWideChar',
      'WideCharToMultiByte',
      'GetLocaleInfoEx',
      'kernel32',
      'DynamicLibrary',
      'latin1.decode',
      'systemEncoding',
    ]) {
      expect(
        source,
        isNot(contains(forbidden)),
        reason: '$forbidden 会让 Dart 侧按整包猜编码（BUG-1522）',
      );
    }

    // 唯一允许的降级是逐字节 U+FFFD：坏字节就地损坏，不牵连同包合法字段。
    // 实参集合钉死「只有这一个解码点，且带 allowMalformed」。
    expect(
      _argumentsOf(source, 'utf8.decode'),
      <String>{'bytes, allowMalformed: true'},
    );
  });
}
