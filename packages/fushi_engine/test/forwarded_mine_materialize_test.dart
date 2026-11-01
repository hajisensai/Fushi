import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_engine/sync/forwarded_mine_materialize.dart';
import 'package:fushi_engine/sync/forwarded_mine_payload.dart';
import 'package:test/test.dart';

/// BUG-2778：跨设备中转的载荷来自任何能写同步后端的一方。凡不是本载荷随附字节的
/// 媒体引用都要剥掉，绝不把对端给的本地路径 / URL 交给下游（下游会读本地文件、
/// 对任意 URL 发 GET）。
void main() {
  Future<Map<String, dynamic>> materializedFields(
    ForwardedMinePayload payload, {
    required bool bundledMediaOnly,
    void Function(Map<String, dynamic> fields)? whileAlive,
  }) => withMaterializedMiningContext<Map<String, dynamic>>(payload, (
    String raw,
    AnkiMiningContext context,
  ) async {
    final Map<String, dynamic> fields = jsonDecode(raw) as Map<String, dynamic>;
    whileAlive?.call(fields);
    return fields;
  }, bundledMediaOnly: bundledMediaOnly);

  test('中转载荷：非随附的单词音频（本地路径 / URL）一律剥掉', () async {
    for (final String ref in <String>[
      '/etc/passwd',
      r'C:\Windows\win.ini',
      'file:///etc/hosts',
      'http://169.254.169.254/latest/meta-data/',
      'https://example.com/a.mp3',
    ]) {
      final Map<String, dynamic> fields = await materializedFields(
        ForwardedMinePayload(
          rawPayloadJson: jsonEncode(<String, Object?>{
            'expression': '猫',
            'audio': ref,
          }),
          sentence: 's',
        ),
        bundledMediaOnly: true,
      );
      expect(fields['audio'], '', reason: ref);
      expect(fields['expression'], '猫');
    }
  });

  test('中转载荷：随附了单词音频字节时 audio 指向本次写出的临时文件', () async {
    late String audioPath;
    late List<int> audioBytes;
    await materializedFields(
      ForwardedMinePayload(
        rawPayloadJson: jsonEncode(<String, Object?>{
          'expression': '猫',
          'audio': '/etc/passwd',
        }),
        sentence: 's',
        wordAudioBytes: Uint8List.fromList(<int>[1, 2, 3]),
        wordAudioExt: '../../evil',
      ),
      bundledMediaOnly: true,
      whileAlive: (Map<String, dynamic> fields) {
        audioPath = fields['audio'] as String;
        audioBytes = File(audioPath).readAsBytesSync();
      },
    );
    expect(audioPath, isNot('/etc/passwd'));
    expect(audioPath, contains('fushi_fwd_mine_'));
    expect(audioPath, endsWith('word_audio.evil'), reason: '扩展名只留字母数字');
    expect(audioBytes, <int>[1, 2, 3]);
  });

  test('中转载荷：词典外字只留随附了字节的条目', () async {
    final Map<String, dynamic> fields = await materializedFields(
      ForwardedMinePayload(
        rawPayloadJson: jsonEncode(<String, Object?>{
          'expression': '猫',
          'dictionaryMedia': jsonEncode(<Map<String, String>>[
            <String, String>{'dictionary': 'A', 'path': 'gaiji/a.png'},
            <String, String>{'dictionary': 'B', 'path': 'gaiji/b.png'},
          ]),
        }),
        sentence: 's',
        dictionaryMedia: <ForwardedDictMedia>[
          ForwardedDictMedia(
            dictionary: 'A',
            path: 'gaiji/a.png',
            bytes: Uint8List.fromList(<int>[9]),
          ),
        ],
      ),
      bundledMediaOnly: true,
    );
    final List<Object?> kept =
        jsonDecode(fields['dictionaryMedia'] as String) as List<Object?>;
    expect(kept, hasLength(1));
    expect((kept.single as Map<String, Object?>)['dictionary'], 'A');
  });

  test('中转载荷：fields 不是 JSON 对象时拒绝（剥不了就不落）', () async {
    await expectLater(
      materializedFields(
        const ForwardedMinePayload(rawPayloadJson: '[1]', sentence: 's'),
        bundledMediaOnly: true,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('非中转（本机 / 已配对主机）载荷：URL 单词音频照旧透传', () async {
    final Map<String, dynamic> fields = await materializedFields(
      ForwardedMinePayload(
        rawPayloadJson: jsonEncode(<String, Object?>{
          'expression': '猫',
          'audio': 'https://example.com/a.mp3',
        }),
        sentence: 's',
      ),
      bundledMediaOnly: false,
    );
    expect(fields['audio'], 'https://example.com/a.mp3');
  });

  group('反馈 PDgaHL5qmj：瘦客户端经主机查词后制卡到主机，插图由主机词典补齐', () {
    // 每次运行一个独立词典名：缓存目录（系统临时目录下 anki-media）是全机共享的，
    // 旧运行留下的同名文件会把「主机没补齐」掩盖成「图在」。
    final String dict = '語彙力・熟語の百科事典 ${DateTime.now().microsecondsSinceEpoch}';
    // 插图路径带子目录 / 中文 / 空格；外字是小 SVG。
    const String illustrationPath = 'img/悩殺 挿絵.png';
    const String gaijiPath = 'gaiji/参照.svg';
    final Uint8List illustrationBytes = Uint8List.fromList(
      List<int>.generate(300 * 1024, (int i) => i & 0xff),
    );
    final Uint8List gaijiBytes = Uint8List.fromList(utf8.encode('<svg/>'));

    File cacheFile(String path) => File(
      '${ankiDictionaryMediaCacheDirPath()}/'
      '${ankiDictionaryMediaCacheFilename(dict, path)}',
    );

    tearDown(() {
      for (final String path in <String>[illustrationPath, gaijiPath]) {
        final File f = cacheFile(path);
        if (f.existsSync()) f.deleteSync();
      }
    });

    /// popup.js 导出的形状：`<a href>` 包 `<img src alt>`；插图无 alt。
    String exported(String placeholder, {String alt = ''}) =>
        '<span data-sc-img=""><a href="$placeholder">'
        '<img alt="$alt" src="$placeholder"></a></span>';

    /// 客户端（iPad）的载荷：词典媒体登记了两条，但客户端本机没有这部词典，
    /// 只搬得来外字的字节（例如本机恰好也装了带同一外字的词典），插图搬不来。
    ForwardedMinePayload clientPayload() => ForwardedMinePayload(
      rawPayloadJson: jsonEncode(<String, Object?>{
        'expression': '悩殺',
        'reading': 'のうさつ',
        'glossary':
            '詳細${exported('fushi_dict_0.png')}'
            '意味${exported('fushi_dict_1.svg', alt: '参照')}',
        'dictionaryMedia': jsonEncode(<Map<String, String>>[
          <String, String>{
            'dictionary': dict,
            'path': illustrationPath,
            'filename': 'fushi_dict_0.png',
          },
          <String, String>{
            'dictionary': dict,
            'path': gaijiPath,
            'filename': 'fushi_dict_1.svg',
          },
        ]),
      }),
      sentence: 's',
      dictionaryMedia: <ForwardedDictMedia>[
        ForwardedDictMedia(
          dictionary: dict,
          path: gaijiPath,
          bytes: gaijiBytes,
        ),
      ],
    );

    /// 主机本机词典的写缓存函数：与 app / 无头服务端的实现同一契约——按
    /// [ankiDictionaryMediaCacheFilename] 命名、已存在跳过、取不到字节跳过。
    final List<String> hostWrites = <String>[];
    Future<void> hostWriter(String dictionaryMediaJson) async {
      final Map<String, Uint8List> hostDictionary = <String, Uint8List>{
        '$dict\u0000$illustrationPath': illustrationBytes,
        '$dict\u0000$gaijiPath': Uint8List.fromList(utf8.encode('<host/>')),
      };
      for (final Object? e
          in jsonDecode(dictionaryMediaJson) as List<Object?>) {
        final Map<String, Object?> m = e! as Map<String, Object?>;
        final String path = m['path']! as String;
        final File f = cacheFile(path);
        if (f.existsSync()) continue;
        final Uint8List? bytes =
            hostDictionary['${m['dictionary']}\u0000$path'];
        if (bytes == null) continue;
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync(bytes, flush: true);
        hostWrites.add(path);
      }
    }

    /// 主机落卡：与 AnkiConnect 同一渲染链路——缓存里有字节才登记映射
    /// （`_storeDictionaryMedia`），再 [AnkiNoteComposer.buildMinedFields] 替换 / 降级。
    Future<String> renderGlossary({
      Future<void> Function(String dictionaryMediaJson)? writer,
    }) => withMaterializedMiningContext<String>(clientPayload(), (
      String raw,
      AnkiMiningContext context,
    ) async {
      final _Composer composer = _Composer();
      final AnkiMiningPayload payload = AnkiMiningPayload.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      final Map<String, String> tags = await composer.tags(
        payload.dictionaryMedia,
        (DictionaryMedia m) async {
          final File f = cacheFile(m.path);
          return f.existsSync() ? f.uri.pathSegments.last : null;
        },
      );
      return composer.render(payload, context, tags)['Glossary']!;
    }, writeHostDictionaryMedia: writer);

    test('无主机补齐（旧行为）：插图 <img> 与外层链接一并消失，外字保留', () async {
      final String glossary = await renderGlossary();
      expect(glossary, isNot(contains('<img alt=""')));
      expect(glossary, isNot(contains('fushi_dict_0.png')));
      expect(
        glossary,
        isNot(
          contains(ankiDictionaryMediaCacheFilename(dict, illustrationPath)),
        ),
      );
      expect(glossary, contains('<a>'), reason: '链接的 href 被摘掉，只剩空壳');
      expect(
        glossary,
        contains('src="${ankiDictionaryMediaCacheFilename(dict, gaijiPath)}"'),
      );
    });

    test('主机补齐：插图与外字都换成真实媒体名，链接保留', () async {
      hostWrites.clear();
      final String glossary = await renderGlossary(writer: hostWriter);
      final String illustration = ankiDictionaryMediaCacheFilename(
        dict,
        illustrationPath,
      );
      final String gaiji = ankiDictionaryMediaCacheFilename(dict, gaijiPath);
      expect(glossary, contains('<a href="$illustration">'));
      expect(glossary, contains('src="$illustration"'));
      expect(glossary, contains('src="$gaiji"'));
      expect(glossary, isNot(contains('fushi_dict_0.')));
      expect(glossary, isNot(contains('fushi_dict_1.')));
      expect(cacheFile(illustrationPath).readAsBytesSync(), illustrationBytes);
      // 随附字节优先：主机只补客户端搬不来的那条，不覆盖客户端给的外字。
      expect(hostWrites, <String>[illustrationPath]);
      expect(cacheFile(gaijiPath).readAsBytesSync(), gaijiBytes);
    });

    test('rawPayloadJson 的 dictionaryMedia 是原生 List 时同样补齐', () async {
      final List<String> seen = <String>[];
      await withMaterializedMiningContext<void>(
        ForwardedMinePayload(
          rawPayloadJson: jsonEncode(<String, Object?>{
            'expression': '悩殺',
            'dictionaryMedia': <Map<String, String>>[
              <String, String>{'dictionary': dict, 'path': illustrationPath},
            ],
          }),
          sentence: 's',
        ),
        (String raw, AnkiMiningContext context) async {},
        writeHostDictionaryMedia: (String json) async => seen.add(json),
      );
      expect(seen, hasLength(1));
      expect(jsonDecode(seen.single), <Object?>[
        <String, Object?>{'dictionary': dict, 'path': illustrationPath},
      ]);
    });

    test('没有登记词典媒体时不调用主机写入方', () async {
      int calls = 0;
      await withMaterializedMiningContext<void>(
        ForwardedMinePayload(
          rawPayloadJson: jsonEncode(<String, Object?>{
            'expression': '悩殺',
            'dictionaryMedia': '[]',
          }),
          sentence: 's',
        ),
        (String raw, AnkiMiningContext context) async {},
        writeHostDictionaryMedia: (String json) async => calls++,
      );
      expect(calls, 0);
    });
  });
}

/// 只为在测试里调用 [AnkiNoteComposer] 的 protected 渲染步骤（与各 Anki 后端同一份）。
class _Composer with AnkiNoteComposer {
  Future<Map<String, String>> tags(
    List<DictionaryMedia> media,
    Future<String?> Function(DictionaryMedia media) store,
  ) => buildDictionaryMediaTags(media, store);

  Map<String, String> render(
    AnkiMiningPayload payload,
    AnkiMiningContext context,
    Map<String, String> tags,
  ) => buildMinedFields(
    fieldMappings: const <String, String>{'Glossary': '{glossary}'},
    payload: payload,
    context: context,
    dictionaryMediaTags: tags,
  );
}
