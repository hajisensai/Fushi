// BUG-1522: libtorrent error_code::message() may use the Windows locale code
// page. Every C ABI response is documented as UTF-8 JSON, so the shared JSON
// serializer must validate non-ASCII sequences before Dart decodes the whole
// Tracker response.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native torrent JSON replaces malformed UTF-8 at the shared boundary',
      () {
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
    expect(serializer, contains('windows_ansi_to_utf8(s)'));
    expect(serializer, contains('out.append(*input, i, width)'));
    expect(source, contains('MultiByteToWideChar('));
    expect(source, contains('WideCharToMultiByte('));
    expect(source, contains('CP_ACP'));
    expect(source, contains('CP_UTF8'));
    expect(source, contains('LOCALE_IDEFAULTANSICODEPAGE'));
    expect(source, contains('GetLocaleInfoEx('));
  });
}
