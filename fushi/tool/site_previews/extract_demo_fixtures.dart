// 把官网 fushi.moe 首页公开的交互 demo 素材抽成中立格式的夹具。
//
// 用法（在 fushi/ 下）：
//   dart run tool/site_previews/extract_demo_fixtures.dart \
//     --site <官网仓根目录> --out <输出目录>
//
// 数据来源（都在官网仓 public/index.html 的内联 <script> 里，单行 JSON 字面量）：
//   FUSHI_MEDIA       {video:[cue], abook:[cue]}，cue = {start, end, text, pos}
//   FUSHI_EXTRA       {manga1..N:{text,pos}, gal:{text,pos}}
//   FUSHI_SENT_AUDIO  句子文本 -> 该句原声（游戏台词语音从这里取）
//   FUSHI_ANKI_DEMO   首页制卡演示卡（唯一一个网页里预设的查词结果）
//   FUSHI_MANGA_DOC   app mangaWindowDocument 生成的整份 HTML（页图 + OCR 框）
//   以及 HTML 标记里的 <video id="demo-video">、.gal-stage <img>、
//   <audio id="demo-audio">，和词库 public/demo/data/termmap.json。
//
// pos 映射的语义（见 index.html 的 termResolve）：pos[字符下标] = {l: 命中长度,
// w: termmap 的查询键}，只有 termmap 里真有该键时网页才会弹词条。
//
// 幂等：每次运行先删掉输出目录下本脚本拥有的子目录 / 文件再重写。
// 任何一段数据找不到都抛 [FixtureError] 并以非零退出码结束，不静默跳过。

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// 抽取失败：信息里写清缺的是哪段数据、去哪里找。
class FixtureError implements Exception {
  FixtureError(this.message);

  final String message;

  @override
  String toString() => 'FixtureError: $message';
}

/// 一条带时间轴的句子（视频字幕 / 有声书）。
class TimedCue {
  TimedCue({
    required this.startMs,
    required this.endMs,
    required this.text,
    required this.pos,
  });

  final int startMs;
  final int endMs;
  final String text;
  final Map<String, dynamic> pos;
}

/// 本脚本在输出目录下拥有的条目；重复运行时整体删除重建。
const List<String> _ownedOutputs = <String>[
  'dict',
  'video',
  'manga',
  'book',
  'gal',
  'demo.json',
];

Future<void> main(List<String> args) async {
  final Map<String, String> opts = _parseArgs(args);
  final String? site = opts['site'];
  final String? out = opts['out'];
  if (site == null || out == null) {
    stderr.writeln(
      'usage: dart run tool/site_previews/extract_demo_fixtures.dart '
      '--site <fushi.moe 仓库根> --out <输出目录>',
    );
    exitCode = 64;
    return;
  }
  try {
    final Map<String, Object?> summary = extractDemoFixtures(
      siteRoot: site,
      outDir: out,
    );
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(summary));
  } on FixtureError catch (e) {
    stderr.writeln(e.toString());
    exitCode = 1;
  }
}

Map<String, String> _parseArgs(List<String> args) {
  final Map<String, String> opts = <String, String>{};
  for (int i = 0; i < args.length; i++) {
    final String a = args[i];
    if (!a.startsWith('--')) {
      throw ArgumentError('未知参数：$a');
    }
    final int eq = a.indexOf('=');
    if (eq > 0) {
      opts[a.substring(2, eq)] = a.substring(eq + 1);
    } else {
      if (i + 1 >= args.length) throw ArgumentError('$a 缺少取值');
      opts[a.substring(2)] = args[++i];
    }
  }
  for (final String k in opts.keys) {
    if (k != 'site' && k != 'out') throw ArgumentError('未知参数：--$k');
  }
  return opts;
}

/// 执行全部抽取，返回各段统计（同时写入输出目录）。
Map<String, Object?> extractDemoFixtures({
  required String siteRoot,
  required String outDir,
}) {
  final String publicDir = p.join(siteRoot, 'public');
  final File indexFile = File(p.join(publicDir, 'index.html'));
  if (!indexFile.existsSync()) {
    throw FixtureError('找不到首页源 ${indexFile.path}（--site 应指向官网仓根目录）');
  }
  final String html = indexFile.readAsStringSync();
  final File termmapFile = File(
    p.join(publicDir, 'demo', 'data', 'termmap.json'),
  );
  if (!termmapFile.existsSync()) {
    throw FixtureError('找不到词库 ${termmapFile.path}');
  }
  final Map<String, dynamic> termmap =
      jsonDecode(termmapFile.readAsStringSync()) as Map<String, dynamic>;

  final Map<String, dynamic> media = _readJsonConst(html, 'FUSHI_MEDIA');
  final Map<String, dynamic> extra = _readJsonConst(html, 'FUSHI_EXTRA');
  final Map<String, dynamic> sentAudio = _readJsonConst(
    html,
    'FUSHI_SENT_AUDIO',
  );
  final Map<String, dynamic> ankiDemo = _readJsonConst(html, 'FUSHI_ANKI_DEMO');
  final String mangaDoc = _readJsonStringConst(html, 'FUSHI_MANGA_DOC');

  final Directory out = Directory(outDir)..createSync(recursive: true);
  for (final String name in _ownedOutputs) {
    final String path = p.join(out.path, name);
    if (FileSystemEntity.isDirectorySync(path)) {
      Directory(path).deleteSync(recursive: true);
    } else if (FileSystemEntity.isFileSync(path)) {
      File(path).deleteSync();
    }
  }

  final Map<String, Object?> dictSummary = _writeDictionaries(
    termmap,
    p.join(out.path, 'dict'),
  );
  final Map<String, Object?> video = _writeVideo(
    html: html,
    publicDir: publicDir,
    media: media,
    termmap: termmap,
    outDir: out.path,
  );
  final Map<String, Object?> manga = _writeManga(
    mangaDoc: mangaDoc,
    publicDir: publicDir,
    extra: extra,
    termmap: termmap,
    outDir: out.path,
  );
  final Map<String, Object?> book = _writeBook(
    html: html,
    publicDir: publicDir,
    media: media,
    termmap: termmap,
    outDir: out.path,
  );
  final Map<String, Object?> gal = _writeGal(
    html: html,
    publicDir: publicDir,
    extra: extra,
    sentAudio: sentAudio,
    termmap: termmap,
    outDir: out.path,
  );

  final Map<String, Object?> preset = _ankiDemoPreset(
    ankiDemo,
    _cuesOf(media, 'video'),
  );

  final Map<String, Object?> demo = <String, Object?>{
    'generator': 'fushi/tool/site_previews/extract_demo_fixtures.dart',
    'source': <String, Object?>{
      'indexHtml': 'public/index.html',
      'termmap': 'public/demo/data/termmap.json',
    },
    'dictionaries': dictSummary,
    'video': video,
    'manga': manga,
    'book': book,
    'gal': gal,
    // 网页里唯一预设的查词结果：首页制卡演示卡（FUSHI_ANKI_DEMO）。
    'presetLookups': <Object?>[preset],
  };
  File(
    p.join(out.path, 'demo.json'),
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(demo));
  return demo;
}

// ---------------------------------------------------------------------------
// index.html 解析

/// 取 `const NAME = <JSON 字面量>;` 一行（官网生成器把数据常量都写成单行）。
String _constLiteral(String html, String name) {
  final RegExp decl = RegExp(
    '^\\s*const\\s+$name\\s*=\\s*(.*?);?\\s*\$',
    multiLine: true,
  );
  final RegExpMatch? m = decl.firstMatch(html);
  if (m == null) {
    throw FixtureError('index.html 里找不到常量 $name（官网 demo 结构变了？）');
  }
  return m.group(1)!;
}

Map<String, dynamic> _readJsonConst(String html, String name) {
  final Object? v = _decodeConst(html, name);
  if (v is! Map<String, dynamic> || v.isEmpty) {
    throw FixtureError('常量 $name 不是非空 JSON 对象（可能已被拆到外部文件）');
  }
  return v;
}

String _readJsonStringConst(String html, String name) {
  final Object? v = _decodeConst(html, name);
  if (v is! String || v.isEmpty) {
    throw FixtureError('常量 $name 不是非空 JSON 字符串');
  }
  return v;
}

Object? _decodeConst(String html, String name) {
  final String literal = _constLiteral(html, name);
  try {
    return jsonDecode(literal);
  } on FormatException catch (e) {
    throw FixtureError('常量 $name 不是合法 JSON：${e.message}');
  }
}

/// 在某个开标签里取属性值（开标签由 [tagPattern] 定位）。
String _attrOfTag(String html, RegExp tagPattern, String attr, String what) {
  final RegExpMatch? tag = tagPattern.firstMatch(html);
  if (tag == null) throw FixtureError('index.html 里找不到 $what');
  final String? v = _attr(tag.group(0)!, attr);
  if (v == null || v.isEmpty) throw FixtureError('$what 没有 $attr 属性');
  return v;
}

String? _attr(String tag, String attr) {
  final RegExpMatch? m = RegExp(
    '(?:^|\\s)${RegExp.escape(attr)}="([^"]*)"',
  ).firstMatch(tag);
  return m == null ? null : _decodeEntities(m.group(1)!);
}

String _decodeEntities(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAllMapped(
      RegExp(r'&#(\d+);'),
      (Match m) => String.fromCharCode(int.parse(m.group(1)!)),
    )
    .replaceAll('&amp;', '&');

/// 站点绝对路径（/demo/media/x.jpg）→ 本地文件，不存在即报错。
File _siteFile(String publicDir, String url, String what) {
  if (!url.startsWith('/')) {
    throw FixtureError('$what 的地址不是站内绝对路径：$url');
  }
  final File f = File(
    p.joinAll(<String>[publicDir, ...url.substring(1).split('/')]),
  );
  if (!f.existsSync()) throw FixtureError('$what 指向的文件不存在：${f.path}');
  return f;
}

void _copy(File src, String dest) {
  Directory(p.dirname(dest)).createSync(recursive: true);
  src.copySync(dest);
}

List<TimedCue> _cuesOf(Map<String, dynamic> media, String key) {
  final Object? raw = media[key];
  if (raw is! List || raw.isEmpty) {
    throw FixtureError('FUSHI_MEDIA.$key 缺失或为空');
  }
  return raw.map((Object? c) {
    final Map<String, dynamic> m = c! as Map<String, dynamic>;
    return TimedCue(
      startMs: ((m['start'] as num) * 1000).round(),
      endMs: ((m['end'] as num) * 1000).round(),
      text: m['text'] as String,
      pos: (m['pos'] as Map<String, dynamic>?) ?? <String, dynamic>{},
    );
  }).toList();
}

/// 由 pos 映射列出网页里点得出词条的位置（termmap 里有该键才算）。
List<Map<String, Object?>> _clickableWords(
  String text,
  Map<String, dynamic> pos,
  Map<String, dynamic> termmap,
) {
  final List<int> idx = pos.keys.map(int.parse).toList()..sort();
  final List<Map<String, Object?>> words = <Map<String, Object?>>[];
  for (final int i in idx) {
    final Map<String, dynamic> e = pos['$i'] as Map<String, dynamic>;
    final String key = e['w'] as String;
    final int len = (e['l'] as num).toInt();
    final Object? hit = termmap[key];
    if (hit is! Map<String, dynamic>) continue;
    final List<dynamic> entries = hit['entries'] as List<dynamic>;
    if (entries.isEmpty) continue;
    final Map<String, dynamic> first = entries.first as Map<String, dynamic>;
    final int end = (i + len).clamp(0, text.length);
    words.add(<String, Object?>{
      'charIndex': i,
      'length': len,
      'surface': text.substring(i, end),
      'termKey': key,
      'expression': first['expression'],
      'reading': first['reading'],
      'entryCount': entries.length,
    });
  }
  return words;
}

// ---------------------------------------------------------------------------
// 词典

String _safeFileName(String name) {
  final String s = name
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
      .trim();
  return s.isEmpty ? '_' : s;
}

class _DictAccumulator {
  final List<List<Object?>> terms = <List<Object?>>[];
  final Set<String> termKeys = <String>{};
  final List<List<Object?>> meta = <List<Object?>>[];
  final Set<String> metaKeys = <String>{};
  int droppedPitchShapes = 0;
  final Set<String> referencedImages = <String>{};
}

void _collectImagePaths(Object? node, Set<String> out) {
  if (node is Map) {
    final Object? path = node['path'];
    if (path is String && (node['tag'] == 'img' || node['type'] == 'image')) {
      out.add(path);
    }
    for (final Object? v in node.values) {
      _collectImagePaths(v, out);
    }
  } else if (node is List) {
    for (final Object? v in node) {
      _collectImagePaths(v, out);
    }
  }
}

Map<String, Object?> _writeDictionaries(
  Map<String, dynamic> termmap,
  String dictDir,
) {
  if (termmap.isEmpty) throw FixtureError('termmap.json 为空');
  final Map<String, _DictAccumulator> dicts = <String, _DictAccumulator>{};
  _DictAccumulator acc(String name) =>
      dicts.putIfAbsent(name, _DictAccumulator.new);

  for (final Object? value in termmap.values) {
    final List<dynamic> entries =
        (value! as Map<String, dynamic>)['entries'] as List<dynamic>;
    for (final Object? raw in entries) {
      final Map<String, dynamic> e = raw! as Map<String, dynamic>;
      final String expression = e['expression'] as String;
      final String reading = (e['reading'] as String?) ?? '';
      final String rules = ((e['rules'] as List<dynamic>?) ?? <dynamic>[]).join(
        ' ',
      );
      final String defTags = _tagString(e['definitionTags']);
      final String termTags = _tagString(e['termTags']);
      for (final Object? g
          in (e['glossaries'] as List<dynamic>?) ?? <dynamic>[]) {
        final Map<String, dynamic> gm = g! as Map<String, dynamic>;
        final String dictName = gm['dictionary'] as String;
        final Object? content = gm['content'];
        final List<Object?> glossary = content is List
            ? List<Object?>.from(content)
            : <Object?>[content];
        final _DictAccumulator d = acc(dictName);
        final String key = jsonEncode(<Object?>[expression, reading, glossary]);
        if (!d.termKeys.add(key)) continue;
        _collectImagePaths(glossary, d.referencedImages);
        d.terms.add(<Object?>[
          expression,
          reading,
          defTags,
          rules,
          0,
          glossary,
          0,
          termTags,
        ]);
      }
      for (final Object? f
          in (e['frequencies'] as List<dynamic>?) ?? <dynamic>[]) {
        final Map<String, dynamic> fm = f! as Map<String, dynamic>;
        final _DictAccumulator d = acc(fm['dictionary'] as String);
        for (final Object? v
            in (fm['frequencies'] as List<dynamic>?) ?? <dynamic>[]) {
          final Map<String, dynamic> vm = v! as Map<String, dynamic>;
          final List<Object?> row = <Object?>[
            expression,
            'freq',
            <String, Object?>{
              'reading': reading,
              'frequency': <String, Object?>{
                'value': vm['value'],
                if (vm['displayValue'] != null)
                  'displayValue': vm['displayValue'],
              },
            },
          ];
          if (d.metaKeys.add(jsonEncode(row))) d.meta.add(row);
        }
      }
      for (final Object? pt
          in (e['pitches'] as List<dynamic>?) ?? <dynamic>[]) {
        final Map<String, dynamic> pm = pt! as Map<String, dynamic>;
        final _DictAccumulator d = acc(pm['dictionary'] as String);
        final List<dynamic> positions =
            (pm['pitchPositions'] as List<dynamic>?) ?? <dynamic>[];
        final List<dynamic> patterns =
            (pm['patterns'] as List<dynamic>?) ?? <dynamic>[];
        final List<dynamic> transcriptions =
            (pm['transcriptions'] as List<dynamic>?) ?? <dynamic>[];
        if (patterns.isNotEmpty || transcriptions.isNotEmpty) {
          // Yomitan v3 term_meta 只有 position 形态；网页数据里的 patterns /
          // transcriptions 没有对应字段，丢弃并计数汇报。
          d.droppedPitchShapes++;
        }
        if (positions.isEmpty) continue;
        final List<Object?> row = <Object?>[
          expression,
          'pitch',
          <String, Object?>{
            'reading': reading,
            'pitches': <Object?>[
              for (final Object? pos in positions)
                <String, Object?>{'position': pos},
            ],
          },
        ];
        if (d.metaKeys.add(jsonEncode(row))) d.meta.add(row);
      }
    }
  }

  Directory(dictDir).createSync(recursive: true);
  final Map<String, Object?> summary = <String, Object?>{};
  final List<String> names = dicts.keys.toList()..sort(_naturalCompare);
  final Set<String> usedFileNames = <String>{};
  for (final String name in names) {
    final _DictAccumulator d = dicts[name]!;
    String fileName = '${_safeFileName(name)}.zip';
    int n = 2;
    while (!usedFileNames.add(fileName.toLowerCase())) {
      fileName = '${_safeFileName(name)}_${n++}.zip';
    }
    final Archive archive = Archive();
    void addJson(String path, Object? data) {
      final List<int> bytes = utf8.encode(jsonEncode(data));
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    }

    addJson('index.json', <String, Object?>{
      'title': name,
      'revision': 'fushi.moe-demo',
      'format': 3,
      'sequenced': false,
      'description':
          'Extracted from the public fushi.moe homepage demo termmap '
          '(only the entries the demo needs).',
    });
    const int chunk = 10000;
    for (int i = 0; i < d.terms.length; i += chunk) {
      addJson(
        'term_bank_${i ~/ chunk + 1}.json',
        d.terms.sublist(i, (i + chunk).clamp(0, d.terms.length)),
      );
    }
    for (int i = 0; i < d.meta.length; i += chunk) {
      addJson(
        'term_meta_bank_${i ~/ chunk + 1}.json',
        d.meta.sublist(i, (i + chunk).clamp(0, d.meta.length)),
      );
    }
    final List<int>? zip = ZipEncoder().encode(archive);
    if (zip == null) throw FixtureError('打包词典 $name 失败');
    File(p.join(dictDir, fileName)).writeAsBytesSync(zip);
    summary[name] = <String, Object?>{
      'file': 'dict/$fileName',
      'terms': d.terms.length,
      'freqMeta': d.meta.where((List<Object?> r) => r[1] == 'freq').length,
      'pitchMeta': d.meta.where((List<Object?> r) => r[1] == 'pitch').length,
      if (d.droppedPitchShapes > 0)
        'droppedPitchPatternsOrTranscriptions': d.droppedPitchShapes,
      if (d.referencedImages.isNotEmpty)
        'missingReferencedImages': d.referencedImages.length,
    };
  }
  return summary;
}

String _tagString(Object? tags) {
  if (tags == null) return '';
  if (tags is String) return tags;
  if (tags is List) {
    return tags
        .map((Object? t) => t is Map ? (t['name'] ?? '').toString() : '$t')
        .where((String s) => s.isNotEmpty)
        .join(' ');
  }
  return '$tags';
}

/// 「词典2」排在「词典10」前面。
int _naturalCompare(String a, String b) {
  final RegExp num = RegExp(r'(\d+)$');
  final RegExpMatch? ma = num.firstMatch(a);
  final RegExpMatch? mb = num.firstMatch(b);
  if (ma != null && mb != null) {
    final String pa = a.substring(0, ma.start);
    final String pb = b.substring(0, mb.start);
    if (pa == pb) {
      return int.parse(ma.group(1)!).compareTo(int.parse(mb.group(1)!));
    }
  }
  return a.compareTo(b);
}

// ---------------------------------------------------------------------------
// 视频

String _srtTime(int ms) {
  final int h = ms ~/ 3600000;
  final int m = (ms ~/ 60000) % 60;
  final int s = (ms ~/ 1000) % 60;
  final int r = ms % 1000;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(h)}:${two(m)}:${two(s)},${r.toString().padLeft(3, '0')}';
}

Map<String, Object?> _writeVideo({
  required String html,
  required String publicDir,
  required Map<String, dynamic> media,
  required Map<String, dynamic> termmap,
  required String outDir,
}) {
  final RegExp videoTag = RegExp(r'<video\b[^>]*\bid="demo-video"[^>]*>');
  final String src = _attrOfTag(
    html,
    videoTag,
    'src',
    '<video id="demo-video">',
  );
  _copy(
    _siteFile(publicDir, src, '视频 demo'),
    p.join(outDir, 'video', 'demo${p.extension(src)}'),
  );
  final List<TimedCue> cues = _cuesOf(media, 'video');
  final StringBuffer srt = StringBuffer();
  for (int i = 0; i < cues.length; i++) {
    final TimedCue c = cues[i];
    srt
      ..writeln(i + 1)
      ..writeln('${_srtTime(c.startMs)} --> ${_srtTime(c.endMs)}')
      ..writeln(c.text)
      ..writeln();
  }
  File(p.join(outDir, 'video', 'demo.srt')).writeAsStringSync(srt.toString());
  return <String, Object?>{
    'file': 'video/demo${p.extension(src)}',
    'subtitles': 'video/demo.srt',
    'siteSource': src,
    'cueCount': cues.length,
    'lastCueEndMs': cues.last.endMs,
    'cues': <Object?>[
      for (int i = 0; i < cues.length; i++)
        <String, Object?>{
          'index': i,
          'startMs': cues[i].startMs,
          'endMs': cues[i].endMs,
          'text': cues[i].text,
          'clickableWords': _clickableWords(cues[i].text, cues[i].pos, termmap),
        },
    ],
  };
}

// ---------------------------------------------------------------------------
// 漫画

/// 解析 `left:12.3%;top:..%;width:..%;height:..%` 四个百分比。
List<double> _pctRect(String style, String what) {
  double read(String k) {
    final RegExpMatch? m = RegExp(
      '(?:^|;)\\s*$k\\s*:\\s*(-?[0-9.]+)%',
    ).firstMatch(style);
    if (m == null) throw FixtureError('$what 的 style 缺 $k 百分比：$style');
    return double.parse(m.group(1)!);
  }

  return <double>[read('left'), read('top'), read('width'), read('height')];
}

double _r2(double v) => (v * 100).roundToDouble() / 100;

Map<String, Object?> _writeManga({
  required String mangaDoc,
  required String publicDir,
  required Map<String, dynamic> extra,
  required Map<String, dynamic> termmap,
  required String outDir,
}) {
  final RegExp pageRe = RegExp(r'<div class="manga-page"[^>]*>');
  final List<RegExpMatch> pageTags = pageRe.allMatches(mangaDoc).toList();
  if (pageTags.isEmpty) {
    throw FixtureError('FUSHI_MANGA_DOC 里找不到 .manga-page（漫画 demo 结构变了？）');
  }
  // 按 sentence 文本索引 FUSHI_EXTRA.mangaN 的 pos 映射。
  final Map<String, Map<String, dynamic>> posBySentence =
      <String, Map<String, dynamic>>{};
  for (final MapEntry<String, dynamic> e in extra.entries) {
    if (!e.key.startsWith('manga')) continue;
    final Map<String, dynamic> v = e.value as Map<String, dynamic>;
    posBySentence[v['text'] as String] =
        (v['pos'] as Map<String, dynamic>?) ?? <String, dynamic>{};
  }

  final List<Map<String, Object?>> pages = <Map<String, Object?>>[];
  final List<String> warnings = <String>[];
  for (int pi = 0; pi < pageTags.length; pi++) {
    final String tag = pageTags[pi].group(0)!;
    final int bodyStart = pageTags[pi].end;
    final int bodyEnd = pi + 1 < pageTags.length
        ? pageTags[pi + 1].start
        : mangaDoc.length;
    final String body = mangaDoc.substring(bodyStart, bodyEnd);
    final int declW = int.parse(_attr(tag, 'data-pw') ?? '0');
    final int declH = int.parse(_attr(tag, 'data-ph') ?? '0');
    final RegExpMatch? imgTag = RegExp(r'<img\b[^>]*>').firstMatch(body);
    final String? src = imgTag == null ? null : _attr(imgTag.group(0)!, 'src');
    if (src == null) throw FixtureError('漫画第 ${pi + 1} 页没有 <img src>');
    final File srcFile = _siteFile(publicDir, src, '漫画第 ${pi + 1} 页页图');
    final String imageName =
        'page-${(pi + 1).toString().padLeft(2, '0')}${p.extension(src)}';
    _copy(srcFile, p.join(outDir, 'manga', imageName));
    final img.Image? decoded = img.decodeImage(srcFile.readAsBytesSync());
    if (decoded == null) throw FixtureError('解码页图失败：${srcFile.path}');
    final int w = decoded.width;
    final int h = decoded.height;
    if (declW > 0 && declH > 0 && (declW != w || declH != h)) {
      warnings.add(
        '第 ${pi + 1} 页 data-pw/ph=${declW}x$declH 与页图实际 ${w}x$h 不一致，'
        '坐标按实际尺寸换算',
      );
    }

    final List<Map<String, Object?>> blocks = <Map<String, Object?>>[];
    final RegExp boxRe = RegExp(
      r'<p class="ocr-box"([^>]*)>(.*?)</p>',
      dotAll: true,
    );
    final RegExp charRe = RegExp(
      r'<span class="ocr-char"([^>]*)>(.*?)</span>',
      dotAll: true,
    );
    for (final RegExpMatch bm in boxRe.allMatches(body)) {
      final String attrs = bm.group(1)!;
      final String style = _attr(attrs, 'style') ?? '';
      final List<double> r = _pctRect(style, 'OCR 框');
      final double bx = r[0] / 100 * w;
      final double by = r[1] / 100 * h;
      final double bw = r[2] / 100 * w;
      final double bh = r[3] / 100 * h;
      final String blockOrientation =
          _attr(attrs, 'data-ocr-orientation') ?? '';

      // 先收字：每个 .ocr-char 自带 data-ocr-orientation，且与 app 实际排版
      // （style 里的 writing-mode）一致；块级属性有时与之不符（见 blockOrientation）。
      final List<RegExpMatch> charMatches = charRe
          .allMatches(bm.group(2)!)
          .toList();
      final Set<String> charOrientations = <String>{
        for (final RegExpMatch cm in charMatches)
          _attr(cm.group(1)!, 'data-ocr-orientation') ?? '',
      }..remove('');
      final bool vertical = charOrientations.length == 1
          ? charOrientations.single == 'vertical'
          : blockOrientation == 'vertical';

      final List<Map<String, Object?>> chars = <Map<String, Object?>>[];
      final List<String> lines = <String>[];
      String? lineKey;
      for (final RegExpMatch cm in charMatches) {
        final String cAttrs = cm.group(1)!;
        final List<double> cr = _pctRect(_attr(cAttrs, 'style') ?? '', 'OCR 字');
        final String ch = _decodeEntities(cm.group(2)!);
        // 同一列（竖排）/ 同一行（横排）的字共享 left+width / top+height。
        final String key = vertical ? '${cr[0]}/${cr[2]}' : '${cr[1]}/${cr[3]}';
        if (key != lineKey || lines.isEmpty) {
          lines.add(ch);
          lineKey = key;
        } else {
          lines[lines.length - 1] += ch;
        }
        final double x0 = bx + cr[0] / 100 * bw;
        final double y0 = by + cr[1] / 100 * bh;
        chars.add(<String, Object?>{
          'char': ch,
          'utf16Start': int.tryParse(_attr(cAttrs, 'data-utf16-start') ?? ''),
          'box': <double>[
            _r2(x0),
            _r2(y0),
            _r2(x0 + cr[2] / 100 * bw),
            _r2(y0 + cr[3] / 100 * bh),
          ],
        });
      }
      final String sentence = _attr(attrs, 'data-manga-sentence') ?? '';
      blocks.add(<String, Object?>{
        'box': <double>[_r2(bx), _r2(by), _r2(bx + bw), _r2(by + bh)],
        'vertical': vertical,
        if ((blockOrientation == 'vertical') != vertical)
          'blockOrientationAttr': blockOrientation,
        'lines': lines,
        'sentence': sentence,
        'sentenceGroup': int.tryParse(
          _attr(attrs, 'data-manga-sentence-group') ?? '',
        ),
        'chars': chars,
      });
    }
    if (blocks.isEmpty) throw FixtureError('漫画第 ${pi + 1} 页没有任何 .ocr-box');
    pages.add(<String, Object?>{
      'image': imageName,
      'width': w,
      'height': h,
      'siteSource': src,
      'blocks': blocks,
    });
  }
  File(
    p.join(outDir, 'manga', 'ocr.json'),
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(pages));

  // 每个句组的可点词（FUSHI_EXTRA.mangaN 按句子文本对上；网页 JS 本身不读它，
  // 漫画真实查词走 iframe 里的选区引擎 + termmap 最长前缀 ≤6 字）。
  final List<Map<String, Object?>> sentences = <Map<String, Object?>>[];
  final Set<String> seen = <String>{};
  for (final Map<String, Object?> page in pages) {
    for (final Object? b in page['blocks']! as List<Object?>) {
      final String s = (b! as Map<String, Object?>)['sentence']! as String;
      if (!seen.add(s)) continue;
      final Map<String, dynamic>? pos = posBySentence[s];
      sentences.add(<String, Object?>{
        'page': page['image'],
        'sentence': s,
        'clickableWords': pos == null ? null : _clickableWords(s, pos, termmap),
      });
    }
  }
  final List<String> unmatchedExtra = posBySentence.keys
      .where((String s) => !seen.contains(s))
      .toList();
  return <String, Object?>{
    'pages': <Object?>[
      for (final Map<String, Object?> pg in pages) 'manga/${pg['image']}',
    ],
    'ocr': 'manga/ocr.json',
    'blockCount': pages.fold<int>(
      0,
      (int n, Map<String, Object?> pg) => n + (pg['blocks']! as List).length,
    ),
    'sentences': sentences,
    if (unmatchedExtra.isNotEmpty)
      'extraSentencesWithoutOcrBox': unmatchedExtra,
    if (warnings.isNotEmpty) 'warnings': warnings,
  };
}

// ---------------------------------------------------------------------------
// 阅读 / 有声书

Map<String, Object?> _writeBook({
  required String html,
  required String publicDir,
  required Map<String, dynamic> media,
  required Map<String, dynamic> termmap,
  required String outDir,
}) {
  final RegExp audioTag = RegExp(r'<audio\b[^>]*\bid="demo-audio"[^>]*>');
  final String src = _attrOfTag(
    html,
    audioTag,
    'src',
    '<audio id="demo-audio">',
  );
  final String audioName = 'audio${p.extension(src)}';
  _copy(_siteFile(publicDir, src, '有声书音频'), p.join(outDir, 'book', audioName));
  final List<TimedCue> cues = _cuesOf(media, 'abook');
  // 网页的 #bookpage 是一个块，所有 cue 依次作为行内 span 接在一起，
  // 数据里没有段落分界——所以正文就是一段。
  final List<String> paragraphs = <String>[
    cues.map((TimedCue c) => c.text).join(),
  ];
  const JsonEncoder enc = JsonEncoder.withIndent('  ');
  File(
    p.join(outDir, 'book', 'text.json'),
  ).writeAsStringSync(enc.convert(paragraphs));
  File(p.join(outDir, 'book', 'cues.json')).writeAsStringSync(
    enc.convert(<Object?>[
      for (final TimedCue c in cues)
        <String, Object?>{
          'startMs': c.startMs,
          'endMs': c.endMs,
          'text': c.text,
        },
    ]),
  );
  return <String, Object?>{
    'text': 'book/text.json',
    'audio': 'book/$audioName',
    'cues': 'book/cues.json',
    'siteSource': src,
    'cueCount': cues.length,
    'lastCueEndMs': cues.last.endMs,
    'cueWords': <Object?>[
      for (int i = 0; i < cues.length; i++)
        <String, Object?>{
          'index': i,
          'text': cues[i].text,
          'clickableWords': _clickableWords(cues[i].text, cues[i].pos, termmap),
        },
    ],
  };
}

// ---------------------------------------------------------------------------
// 游戏

Map<String, Object?> _writeGal({
  required String html,
  required String publicDir,
  required Map<String, dynamic> extra,
  required Map<String, dynamic> sentAudio,
  required Map<String, dynamic> termmap,
  required String outDir,
}) {
  final RegExpMatch? stage = RegExp(
    r'<div class="gal-stage">\s*(<img\b[^>]*>)',
  ).firstMatch(html);
  if (stage == null) {
    throw FixtureError('index.html 里找不到 .gal-stage 下的背景 <img>');
  }
  final String? bg = _attr(stage.group(1)!, 'src');
  if (bg == null) throw FixtureError('.gal-stage <img> 没有 src');
  _copy(
    _siteFile(publicDir, bg, '游戏背景截图'),
    p.join(outDir, 'gal', 'background${p.extension(bg)}'),
  );

  // FUSHI_EXTRA 里以 gal 开头的键都是台词（当前官网只有一条 `gal`）。
  final List<String> keys =
      extra.keys.where((String k) => k.startsWith('gal')).toList()..sort();
  if (keys.isEmpty) throw FixtureError('FUSHI_EXTRA 里没有 gal 台词');
  final List<Map<String, Object?>> lines = <Map<String, Object?>>[];
  final List<Map<String, Object?>> details = <Map<String, Object?>>[];
  for (int i = 0; i < keys.length; i++) {
    final Map<String, dynamic> v = extra[keys[i]] as Map<String, dynamic>;
    final String text = v['text'] as String;
    final Object? voiceUrl = sentAudio[text];
    if (voiceUrl is! String) {
      throw FixtureError('FUSHI_SENT_AUDIO 里没有游戏台词「$text」的语音');
    }
    final String voiceName =
        'voice-${(i + 1).toString().padLeft(2, '0')}${p.extension(voiceUrl)}';
    _copy(
      _siteFile(publicDir, voiceUrl, '游戏台词语音'),
      p.join(outDir, 'gal', voiceName),
    );
    lines.add(<String, Object?>{'text': text, 'voice': 'gal/$voiceName'});
    details.add(<String, Object?>{
      'key': keys[i],
      'text': text,
      'voice': 'gal/$voiceName',
      'siteVoiceSource': voiceUrl,
      'clickableWords': _clickableWords(
        text,
        (v['pos'] as Map<String, dynamic>?) ?? <String, dynamic>{},
        termmap,
      ),
    });
  }
  File(
    p.join(outDir, 'gal', 'lines.json'),
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(lines));

  // 台词命中框几何：GAL_CELL（JS）+ .gal-stage .galtext（CSS），百分比相对截图。
  final RegExpMatch? cell = RegExp(
    r'GAL_CELL\s*=\s*\{\s*left:\s*([0-9.]+),\s*pitch:\s*([0-9.]+)\s*\}',
  ).firstMatch(html);
  final RegExpMatch? band = RegExp(
    r'\.gal-stage \.galtext \{[^}]*top:\s*([0-9.]+)%;\s*height:\s*([0-9.]+)%',
  ).firstMatch(html);
  return <String, Object?>{
    'background': 'gal/background${p.extension(bg)}',
    'lines': 'gal/lines.json',
    'siteBackgroundSource': bg,
    'lineDetails': details,
    'textCellGeometryPercent': cell == null || band == null
        ? null
        : <String, Object?>{
            'firstCharLeft': double.parse(cell.group(1)!),
            'charPitch': double.parse(cell.group(2)!),
            'top': double.parse(band.group(1)!),
            'height': double.parse(band.group(2)!),
          },
  };
}

// ---------------------------------------------------------------------------
// 预设查词点

Map<String, Object?> _ankiDemoPreset(
  Map<String, dynamic> anki,
  List<TimedCue> videoCues,
) {
  final String expression = anki['expression'] as String;
  final String sentenceHtml = (anki['sentence'] as String?) ?? '';
  final String sentence = sentenceHtml.replaceAll(RegExp(r'<[^>]*>'), '');
  final int cueIndex = videoCues.indexWhere((TimedCue c) => c.text == sentence);
  if (cueIndex < 0) {
    throw FixtureError('FUSHI_ANKI_DEMO 的例句「$sentence」不在视频字幕里');
  }
  final int charIndex = sentence.indexOf(expression);
  return <String, Object?>{
    'origin': 'FUSHI_ANKI_DEMO（首页制卡演示卡）',
    'section': 'video',
    'expression': expression,
    'reading': anki['reading'],
    'sentence': sentence,
    'cueIndex': cueIndex,
    'cueStartMs': videoCues[cueIndex].startMs,
    'cueEndMs': videoCues[cueIndex].endMs,
    'charIndex': charIndex,
    'length': expression.length,
    'miscInfo': anki['miscInfo'],
  };
}
