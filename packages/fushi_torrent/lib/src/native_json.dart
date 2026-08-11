import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _MultiByteToWideCharNative = Int32 Function(
  Uint32 codePage,
  Uint32 flags,
  Pointer<Uint8> input,
  Int32 inputLength,
  Pointer<Uint16> output,
  Int32 outputLength,
);
typedef _MultiByteToWideCharDart = int Function(
  int codePage,
  int flags,
  Pointer<Uint8> input,
  int inputLength,
  Pointer<Uint16> output,
  int outputLength,
);
typedef _GetLocaleInfoExNative = Int32 Function(
  Pointer<Utf16> localeName,
  Uint32 localeType,
  Pointer<Utf16> output,
  Int32 outputLength,
);
typedef _GetLocaleInfoExDart = int Function(
  Pointer<Utf16> localeName,
  int localeType,
  Pointer<Utf16> output,
  int outputLength,
);

/// Decodes a malloc-owned C ABI payload after its bytes have been copied.
///
/// New native builds guarantee UTF-8 JSON. `allowMalformed` keeps older
/// bundled Windows DLLs readable when a localized socket error was emitted in
/// the locale's default ANSI code page instead, even when the system-wide
/// active code page has separately been switched to UTF-8.
Object? decodeNativeTorrentJsonBytes(Uint8List bytes) {
  String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    text = Platform.isWindows
        ? (_WindowsAnsiDecoder.decode(bytes) ??
            utf8.decode(bytes, allowMalformed: true))
        : utf8.decode(bytes, allowMalformed: true);
  }
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

final class _WindowsAnsiDecoder {
  static const int _localeDefaultAnsiCodePage = 0x00001004;

  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

  static final _MultiByteToWideCharDart _multiByteToWideChar = _kernel32
      .lookupFunction<_MultiByteToWideCharNative, _MultiByteToWideCharDart>(
    'MultiByteToWideChar',
  );
  static final _GetLocaleInfoExDart _getLocaleInfoEx =
      _kernel32.lookupFunction<_GetLocaleInfoExNative, _GetLocaleInfoExDart>(
    'GetLocaleInfoEx',
  );

  static int _resolveCodePage() {
    final Pointer<Uint16> output = calloc<Uint16>(16);
    try {
      final int written = _getLocaleInfoEx(
        nullptr.cast<Utf16>(),
        _localeDefaultAnsiCodePage,
        output.cast<Utf16>(),
        16,
      );
      if (written <= 1) return 0;
      return int.tryParse(output.cast<Utf16>().toDartString()) ?? 0;
    } finally {
      calloc.free(output);
    }
  }

  static String? decode(Uint8List bytes) {
    if (bytes.isEmpty) return '';
    final Pointer<Uint8> input = calloc<Uint8>(bytes.length);
    try {
      input.asTypedList(bytes.length).setAll(0, bytes);
      final int codePage = _resolveCodePage();
      final int requiredUnits = _multiByteToWideChar(
        codePage,
        0,
        input,
        bytes.length,
        nullptr.cast<Uint16>(),
        0,
      );
      if (requiredUnits <= 0) return null;
      final Pointer<Uint16> output = calloc<Uint16>(requiredUnits);
      try {
        final int writtenUnits = _multiByteToWideChar(
          codePage,
          0,
          input,
          bytes.length,
          output,
          requiredUnits,
        );
        if (writtenUnits <= 0) return null;
        return output.cast<Utf16>().toDartString(length: writtenUnits);
      } finally {
        calloc.free(output);
      }
    } finally {
      calloc.free(input);
    }
  }
}
