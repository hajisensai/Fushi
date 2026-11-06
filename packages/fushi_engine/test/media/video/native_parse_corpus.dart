// 媒体名 / 字幕时序 / Fribb 原生解析回归用的确定性语料生成器（固定种子）。
//
// 删旧 Dart 实现前，用旧实现跑这里生成的语料，把输出的 FNV-1a 摘要钉进
// native_media_parse_vectors_test.dart；新实现（Rust + FFI）必须逐条一致。
// 语料刻意覆盖规则边界：每条规则的触发 / 不触发写法、全角半角括号与分隔符、JS `\s`
// 与 Dart `trim` 的差集（U+0085）、大小写折叠的陷阱（KELVIN SIGN、İ、ſ）、孤立代理、
// 星位字符，以及 JSON 的重复键 / 转义键 / 各类非法 id 值。
library;

import 'dart:convert';
import 'dart:math';

/// 64 位 FNV-1a，按 UTF-16 码元累加（Dart VM 整数乘法按 64 位回绕）。
int fnv1a64(Iterable<String> items) {
  int hash = 0xcbf29ce484222325;
  for (final String item in items) {
    for (final int unit in item.codeUnits) {
      hash ^= unit;
      hash *= 0x100000001b3;
    }
    hash ^= 0x1f;
    hash *= 0x100000001b3;
  }
  return hash;
}

const List<String> _special = <String>[
  '[',
  ']',
  '(',
  ')',
  '【',
  '】',
  '（',
  '）',
  ' - ',
  ' – ',
  ' — ',
  ' ‐ ',
  '-',
  '.',
  '_',
  ' ',
  '  ',
  '　', //
  '~',
  '～',
  '〜',
  ':',
  '：',
  ': ',
  '#',
  '#04',
  'S01E04',
  's1ep4',
  'S2',
  's03',
  'E04',
  'EP 3',
  'Ep.3', //
  'EP04',
  'e.5',
  '第三季',
  '第2期',
  '第十二季',
  '第二十一期',
  '第十季',
  '第零季',
  '第两季',
  '2nd Season', //
  '3rd season',
  'Season 3',
  'Season.2',
  'Part 2',
  'part.3',
  'II',
  'III',
  'IV',
  'Ⅲ',
  'Ⅱ',
  'Ⅹ',
  'Ⅰ', //
  '1080p',
  '720P',
  '4K',
  '8k',
  '1920x1080',
  '1280×720',
  '2160i',
  'x265',
  'x.264',
  'h264',
  'HEVC-10bit', //
  '10bit',
  'Hi10P',
  'Ma444',
  'yuv420p10le',
  'AAC',
  'FLACx2',
  'WEB-DL',
  'WebRip',
  'Baha',
  'B-Global', //
  'at-x',
  'CHT',
  'CHS&CHT',
  'gb&big5',
  'JPSC',
  '简繁内封',
  '简日双语',
  '桜都字幕组',
  '字幕社',
  '新番', //
  '十月新番',
  'Movie',
  'the movie',
  'The Movie',
  '剧场版',
  '劇場版',
  '映画',
  '総集編',
  'Gekijouban', //
  'gekijouban',
  '2023',
  '1999',
  '2049',
  '2027',
  '2028',
  '1900',
  '04',
  '4',
  '12',
  '012',
  '100',
  '1000', //
  '13 END',
  '13完',
  '13 fin',
  '第04话',
  '第4集',
  '第 5 回',
  '第2巻',
  '12話',
  '12集',
  '12话',
  'v2',
  'V3', //
  'A1B2C3D4',
  '12345678',
  '.mkv',
  '.mp4',
  '.RMVB',
  '.Mkv',
  '.txt',
  '.ts',
  'VID_20260701',
  'IMG 0231', //
  'dsc_0001',
  'gopro 1',
  '2026-07-01 21-03-55',
  '20260701',
  '2026年7月1日',
  '新建文件夹', //
  'New folder (2)',
  'Downloads',
  'D:',
  'a',
  'END',
  'Fin',
  '完',
  'K',
  'mKv',
  'İ', //
  '\u0085',
  ' ',
  ' ',
  ' ',
  '\n',
  '\t',
  '﻿',
  '\uD800',
  '\uDC00',
  '\u{1F600}',
  'ſ', //
  'K',
  'Re: Zero',
  'Re:Zero',
  'Mob Psycho 100',
  'Gundam 00',
  'Steins;Gate 0',
  'Ranma 1/2', //
  'Hibike! Euphonium 2',
  'Ip Man 2',
  '无职转生Ⅲ',
  'ドライブ行かない_',
  'Death Race 2000',
  '[4th - 14]', //
  '[S4 - 14]',
  '[第4季 - 14]',
  '[4th Season - 14]',
  '[Season 4 - 14]',
  '[01-12]',
  '[第01-12话]', //
  '[Disc 2]',
  '[招募新人 - 详情见置顶]',
  '/',
  '\\',
  '//',
  ' / ',
  'Sub',
  'ja',
  'Netflix',
  '+',
  '&',
  ',', //
  'hevc-aac',
  'web-dl-x265',
  'cr',
  'nf',
  'bd',
  'BDRip',
  'Remux',
  'Frieren',
  'Sousou no Frieren', //
  'Lilith-Raws',
  'ANi',
  'Mushoku Tensei',
  '無職転生',
  '葬送のフリーレン',
  '進撃の巨人',
  'VCB-Studio', //
  'Kimi no Na wa',
  'Yuru Camp△',
  '某科学的超电磁炮',
  'Title',
  'Episode',
  'OVA',
  'SP',
  'NCOP',
  'Vol.2', //
];

/// 旧 filename_parser.dart 源码里出现过的全部非 ASCII 字符（注释外）。
const String _sourceNonAscii =
    '·×‐–—ⅡⅩ　【】〜぀ヿ㐀一七三下两中九二五件会体內八六内分剧劇动十双四回场場外夹字季完封屋嵌'
    '巻幕年建影总挂掛文新日时映會月期桌档漫片版电画番社秒第简篇簡組総編總繁组视話語话语载队隊集'
    '雙零面频體鿿豈﫿（）：～';

List<String> _vocabulary() => <String>{
  ..._special,
  for (final int r in _sourceNonAscii.runes) String.fromCharCode(r),
}.toList()..sort();

String _randomName(Random rnd, List<String> vocab) {
  final int n = 1 + rnd.nextInt(10);
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < n; i++) {
    out.write(vocab[rnd.nextInt(vocab.length)]);
    if (rnd.nextInt(3) > 0) {
      out.write(const <String>[' ', '.', '_', ' - ', ''][rnd.nextInt(5)]);
    }
  }
  return out.toString();
}

/// 文件名 / 目录名语料。
List<String> filenameCorpus(int count, {int seed = 20261018}) {
  final Random rnd = Random(seed);
  final List<String> vocab = _vocabulary();
  return List<String>.generate(count, (_) => _randomName(rnd, vocab));
}

/// 完整路径语料（`/` 与 `\` 混用）。
List<String> pathCorpus(int count, {int seed = 20261019}) {
  final Random rnd = Random(seed);
  final List<String> vocab = _vocabulary();
  return List<String>.generate(
    count,
    (_) => List<String>.generate(
      1 + rnd.nextInt(4),
      (_) => rnd.nextInt(4) == 0
          ? vocab[rnd.nextInt(vocab.length)]
          : _randomName(rnd, vocab),
    ).join(rnd.nextBool() ? '/' : '\\'),
  );
}

const List<String> _subtitlePieces = <String>[
  '00:01:02,345',
  '1:02.345',
  '01:02.3',
  '0:00:01.5',
  '99:59:59,999',
  '1234:56:01,000',
  '59:59.99', //
  '60:00:00,000',
  '00:60:00,000',
  ' --> ',
  '-->',
  '->',
  ' -->\t',
  '\n',
  '\r\n',
  '\r',
  ' ', //
  'Dialogue: 0,',
  'Dialogue:',
  ' Dialogue :',
  'dialogue: 0,',
  'Comment: 0,',
  '0:01:02.34,', //
  '0:01:05.67,',
  ',',
  ', ',
  ' ',
  '　',
  '\u0085',
  'Default,,0,0,0,,text',
  'WEBVTT',
  '1',
  '12', //
  '123',
  ':',
  '.',
  '::',
  '0',
  '5',
  '9',
  'x',
  '中文',
  '﻿',
  '[Events]',
  '\t',
  '00:00:00,000', //
  '1:2:3,4', '1:2.3', //
];

/// 字幕原文语料。
List<String> subtitleCorpus(int count, {int seed = 20261020}) {
  final Random rnd = Random(seed);
  return List<String>.generate(count, (_) {
    final StringBuffer out = StringBuffer();
    for (int i = 1 + rnd.nextInt(30); i > 0; i--) {
      out.write(_subtitlePieces[rnd.nextInt(_subtitlePieces.length)]);
    }
    return out.toString();
  });
}

const List<String> _jsonScalars = <String>[
  '1',
  '0',
  '-1',
  '-0',
  '7',
  '12345',
  '9223372036854775807',
  '9223372036854775808', //
  '-9223372036854775808',
  '1.0',
  '1e2',
  '2E0',
  '"5"',
  '" 6 "',
  '"0x1F"',
  '"-3"',
  '"+4"',
  '"\\u0037"', //
  '"abc"',
  '""',
  '"\\u00a08"',
  '"\\u00858"',
  'true',
  'false',
  'null',
  '[]',
  '[1]',
  '["2", 3]', //
  '[0, -1, "x", 9]',
  '{}',
  '{"tv": 5}',
  '{"movie": [128]}',
  '{"tv": 1, "tv": 2}', //
  '{"movie": [0, "7"]}', '{"tv": "9", "movie": 3}', '{"tmdb": 0, "tvdb": 2}', //
  '{"tmdb": "1", "tmdb": -1}',
  '{"t\\u006ddb": 4}',
  '"TV"',
  '" MOVIE "',
  '"  "',
  '"\\ud800x"', //
  '"OVA\\n"', '[[1]]', '{"tv": [[2]]}', '{"tv": {"x": 1}}', //
];

const List<String> _jsonKeys = <String>[
  'anidb_id',
  'mal_id',
  'anilist_id',
  'tvdb_id',
  'themoviedb_id',
  'season',
  'episode_offset',
  'type', //
  'anidb\\u005fid', 'kitsu_id', 'x', //
];

/// Fribb 全表形状的 JSON 语料（含约三成非法 / 非数组文档）。
List<String> fribbCorpus(int count, {int seed = 20261021}) {
  final Random rnd = Random(seed);
  String scalar() => _jsonScalars[rnd.nextInt(_jsonScalars.length)];
  return List<String>.generate(count, (_) {
    final List<String> rows = <String>[];
    for (int i = rnd.nextInt(8); i > 0; i--) {
      if (rnd.nextInt(12) == 0) {
        rows.add(scalar());
        continue;
      }
      final List<String> fields = <String>[
        if (rnd.nextInt(5) > 0) '"anidb_id": ${1 + rnd.nextInt(4)}',
      ];
      for (int k = rnd.nextInt(7); k > 0; k--) {
        fields.add(
          '"${_jsonKeys[rnd.nextInt(_jsonKeys.length)]}": ${scalar()}',
        );
      }
      fields.shuffle(rnd);
      rows.add('{${fields.join(', ')}}');
    }
    String doc = '[${rows.join(',\n')}]';
    switch (rnd.nextInt(10)) {
      case 0:
        final int at = rnd.nextInt(doc.length);
        doc = doc.substring(0, at) + doc.substring(at + 1);
      case 1:
        const List<String> junk = <String>[
          ',', ']', '}', '"', ':', 'x', ' ', ' ', '0', '\\', //
        ];
        final int at = rnd.nextInt(doc.length + 1);
        doc =
            doc.substring(0, at) +
            junk[rnd.nextInt(junk.length)] +
            doc.substring(at);
      case 2:
        doc = scalar();
      default:
        break;
    }
    return doc;
  });
}

/// 解析结果的规范编码（全字段）：对拍与摘要共用。
String encodeParsedFields(
  String title,
  String? secondaryTitle,
  int? episode,
  int? season,
  int? year,
  String? titleWithTrailingYear,
  String? releaseGroup,
  String? resolution,
  bool isMovieHint,
) => jsonEncode(<Object?>[
  title.codeUnits,
  secondaryTitle?.codeUnits,
  episode,
  season,
  year,
  titleWithTrailingYear?.codeUnits,
  releaseGroup?.codeUnits,
  resolution?.codeUnits,
  isMovieHint,
]);
