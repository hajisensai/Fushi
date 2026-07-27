import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki_core/src/utils/stable_hash.dart';

/// FNV-1a 稳定哈希金标测试（G3 收敛守卫）。
///
/// 全部向量在收敛**之前**用当时散落各处的手写实现现算固化——这些哈希值已持久化
/// 在云端备份资产名（video_manifest / deletion_propagation）、漫画 OCR 断点缓存
/// 目录名（hibiki_manga_ocr_host）、有声书持久目录名（audiobook_storage）与本地
/// 音频缓存文件名（local_audio_db）里，任何输出漂移都等于孤儿化用户已有数据。
/// 三种输入（ASCII / CJK / 含代理对 emoji）足以区分「UTF-16 码元」「UTF-8 字节」
/// 「码元拆高低字节」三种口径：ASCII 下三者同值，CJK / emoji 下全部分岔。
void main() {
  group('fnv1a32Hex(utf8) — audiobook_storage / local_audio_db 强口径', () {
    test('golden vectors', () {
      expect(fnv1a32Hex(utf8.encode('')), '811c9dc5');
      expect(fnv1a32Hex(utf8.encode('video/abc')), 'fd1f8a47');
      expect(fnv1a32Hex(utf8.encode('進撃の巨人')), '9d0d1d4f');
      expect(fnv1a32Hex(utf8.encode('a\u{1F600}b')), '88a361a9');
      expect(fnv1a32Hex(utf8.encode('nhk16\n猫.mp3')), 'fefaefdd');
    });
  });

  group('fnv1a32Hex(codeUnits) — local_audio_db 旧弱口径（仅迁移路径复现用）', () {
    test('golden vectors', () {
      expect(fnv1a32Hex(''.codeUnits), '811c9dc5');
      expect(fnv1a32Hex('video/abc'.codeUnits), 'fd1f8a47');
      expect(fnv1a32Hex('進撃の巨人'.codeUnits), 'ea3612fa');
      expect(fnv1a32Hex('a\u{1F600}b'.codeUnits), '8fca8501');
      expect(fnv1a32Hex('src1\na.mp3'.codeUnits), 'a60fad2d');
      expect(fnv1a32Hex('nhk16\n猫.mp3'.codeUnits), '969e5240');
    });

    test('ASCII 输入下弱口径 == 强口径（旧 ASCII 缓存键零迁移）', () {
      const String key = 'src1\na.mp3';
      expect(fnv1a32Hex(key.codeUnits), fnv1a32Hex(utf8.encode(key)));
    });

    test('BUG-1124：弱口径对 CJK 真实碰撞，强口径区分', () {
      // 生日搜索（种子 42、40 万样本内第 151719 个）找到的真实碰撞对：
      // local_audio 缓存键形态 '$source\n$file'，两个不同音频文件塌缩到同一
      // 缓存文件名 → 第二个词条永远播放第一个词条的音频。
      const String k1 = 'jpod\n肌陒衎柚.mp3';
      const String k2 = 'jpod\n汅肘鹾圃.mp3';
      expect(fnv1a32Hex(k1.codeUnits), 'a0c11ea4');
      expect(fnv1a32Hex(k2.codeUnits), 'a0c11ea4',
          reason: '弱口径（16 位码元整体 XOR）下两键碰撞——BUG-1124 根因实证');
      expect(fnv1a32Hex(utf8.encode(k1)), '8845c26a');
      expect(fnv1a32Hex(utf8.encode(k2)), '99718822',
          reason: 'UTF-8 逐字节强口径必须区分这对键');
    });
  });

  group('fnv1a32Utf16PairHex — video_manifest / deletion_propagation 口径', () {
    test('golden vectors', () {
      expect(fnv1a32Utf16PairHex(''), '811c9dc5');
      expect(fnv1a32Utf16PairHex('video/abc'), '03ffd97b');
      expect(fnv1a32Utf16PairHex('進撃の巨人'), '6755ac01');
      expect(fnv1a32Utf16PairHex('a\u{1F600}b'), '39159885');
    });
  });

  group('fnv1a64Hex(utf8) — hibiki_manga_ocr_host 口径', () {
    test('golden vectors（含历史负号形态，勿「修正」）', () {
      // Dart VM 有符号 64 位：哈希为负时 toRadixString(16) 带 '-'（17 字符），
      // 该形态已固化进 vol_<slug> 断点缓存目录名。
      expect(fnv1a64Hex(utf8.encode('')), '-340d631b7bdddcdb');
      expect(fnv1a64Hex(utf8.encode('video/abc')), '1f90a1b96f6ccce7');
      expect(fnv1a64Hex(utf8.encode('進撃の巨人')), '3573bba886f8926f');
      expect(fnv1a64Hex(utf8.encode('a\u{1F600}b')), '33c526094d790e49');
    });
  });
}
