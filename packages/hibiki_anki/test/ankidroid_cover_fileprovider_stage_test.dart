import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

/// BUG-825 回归守卫：安卓阅读器制卡书籍封面缺失。
///
/// 根因：AnkiDroid 经原生 `FileProvider.getUriForFile` 摄取媒体，FileProvider 只服务
/// `provider_paths.xml` 声明过的根（code_cache/files/cache/external*）。句子音频/视频封面/
/// 词典媒体都先落在 Dart 的 [Directory.systemTemp]（=Android code_cache）下，故能被服务；
/// 唯独**书籍封面**直接从 EPUB 解压目录取——解压目录 base 是
/// `getApplicationDocumentsDirectory()` = `/data/data/<pkg>/app_flutter`（不在任何配置根
/// 下），`getUriForFile` 抛「Failed to find configured root」被吞掉 → coverRef=null →
/// `{card-image}` 恒空（仅 AnkiDroid；AnkiConnect 传字节、书架直接读文件，都正常）。
///
/// 修复：[AnkiRepository] 把交给 AnkiDroid 的媒体在进原生前，若源不在 code_cache
/// （[Directory.systemTemp]）下就先复制进 FileProvider 覆盖的 `anki-media` 缓存。
class _ConfiguredAnkiRepository extends AnkiRepository {
  _ConfiguredAnkiRepository(this.settings);

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}

const AnkiSettings _settings = AnkiSettings(
  selectedDeckId: 1,
  selectedNoteTypeId: 2,
  availableDecks: <AnkiDeck>[AnkiDeck(id: 1, name: 'Mining')],
  availableNoteTypes: <AnkiNoteType>[
    AnkiNoteType(
      id: 2,
      name: 'Hibiki',
      fields: <String>['Expression', 'Picture'],
    ),
  ],
  fieldMappings: <String, String>{
    'Expression': '{expression}',
    'Picture': '{card-image}',
  },
  allowDupes: true,
);

// 最小合法 JPEG（SOI + APP0 + EOI），让封面被识别成 .jpg。
final List<int> _jpegBytes = <int>[
  0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, //
  0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, //
  0x01, 0x00, 0x00, 0x01, 0x00, 0x01, //
  0x00, 0x00, 0xFF, 0xD9,
];

const String _payload = '{"expression":"言葉"}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('app.hibiki.reader/anki');

  late List<Map<String, String>> mediaCalls; // {preferredName, filename}

  setUp(() {
    mediaCalls = <Map<String, String>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      switch (call.method) {
        case 'requestAnkidroidPermissions':
          return true;
        case 'addFileToMedia':
          final args = Map<String, dynamic>.from(call.arguments as Map);
          mediaCalls.add(<String, String>{
            'preferredName': args['preferredName'] as String,
            'filename': args['filename'] as String,
          });
          // 原生实现回传媒体在 collection 内的真实文件名；这里回 preferredName 足够。
          return args['preferredName'] as String;
        case 'addNote':
          return true;
        default:
          fail('Unexpected AnkiDroid channel call: ${call.method}');
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Map<String, String> _coverCall() => mediaCalls.firstWhere(
        (Map<String, String> c) =>
            c['preferredName']!.startsWith('hibiki_cover_'),
        orElse: () => fail('制卡没有向 AnkiDroid 提交封面媒体（addFileToMedia 未收到 cover）'),
      );

  group('BUG-825 book cover FileProvider staging (AnkiDroid)', () {
    test(
        '封面源在 code_cache(systemTemp) 之外(模拟 app_flutter 解压目录) → 被搬进 anki-media 缓存',
        () async {
      // 造一个不在 systemTemp 下的“解压目录”封面（真实 bug：app_flutter 不在配置根内）。
      final Directory outside = Directory(
          '${Directory.current.path}/.dart_tool/hibiki_bug825_extract');
      outside.createSync(recursive: true);
      addTearDown(() {
        if (outside.existsSync()) outside.deleteSync(recursive: true);
      });
      final File cover = File('${outside.path}/Cover.jpg')
        ..writeAsBytesSync(_jpegBytes);
      // 前置断言：这个源确实不在 systemTemp 下（否则本测无意义）。
      expect(cover.path.startsWith(Directory.systemTemp.path), isFalse);

      final MineOutcome outcome =
          await _ConfiguredAnkiRepository(_settings).mineEntry(
        rawPayloadJson: _payload,
        context: AnkiMiningContext(
          sentence: 'これは言葉です。',
          coverPath: cover.path,
          source: AnkiMiningSource.book,
        ),
      );
      expect(outcome.result, MineResult.success);

      final String stagedPath = _coverCall()['filename']!;
      // 交给原生 FileProvider 的路径必须落在 systemTemp(=code_cache) 下，而不是原
      // app_flutter 解压路径——否则 getUriForFile 抛「Failed to find configured root」。
      expect(
        stagedPath.startsWith(Directory.systemTemp.path),
        isTrue,
        reason: '封面必须被搬进 FileProvider 覆盖的 code_cache 缓存，'
            '实际 filename=$stagedPath',
      );
      expect(stagedPath, isNot(cover.path));
      // 搬进去的副本必须真实存在且内容一致（原生要读它）。
      final File staged = File(stagedPath);
      expect(staged.existsSync(), isTrue);
      expect(staged.readAsBytesSync(), _jpegBytes);
    });

    test('封面源已在 code_cache(systemTemp) 下 → 原样提交，不多余复制(无回归)', () async {
      final Directory inside =
          Directory.systemTemp.createTempSync('hibiki_bug825_incache');
      addTearDown(() {
        if (inside.existsSync()) inside.deleteSync(recursive: true);
      });
      final File cover = File('${inside.path}/cover.jpg')
        ..writeAsBytesSync(_jpegBytes);
      expect(cover.path.startsWith(Directory.systemTemp.path), isTrue);

      final MineOutcome outcome =
          await _ConfiguredAnkiRepository(_settings).mineEntry(
        rawPayloadJson: _payload,
        context: AnkiMiningContext(
          sentence: 'これは言葉です。',
          coverPath: cover.path,
          source: AnkiMiningSource.book,
        ),
      );
      expect(outcome.result, MineResult.success);
      expect(_coverCall()['filename'], cover.path,
          reason: '已在 code_cache 下的媒体不应被重复复制，路径应原样传给原生');
    });

    test('源码接线守卫：_addMediaFile 必经 _stageForMediaProvider，禁止裸传 filePath', () {
      final File src = File('lib/src/ankidroid/anki_repository.dart');
      expect(src.existsSync(), isTrue,
          reason: '测试须在 packages/hibiki_anki 目录下运行');
      final String code = src.readAsStringSync();
      expect(code.contains('_stageForMediaProvider'), isTrue,
          reason: '暂存到 FileProvider 覆盖根的收口函数必须存在');
      // 交给原生的 filename 必须是 staged 路径，不能回退成裸 filePath（BUG-825 回归）。
      expect(code.contains("'filename': stagedPath"), isTrue,
          reason: 'addFileToMedia 必须提交 stagedPath');
      expect(code.contains("'filename': filePath"), isFalse,
          reason: '一旦改回裸 filePath，app_flutter 封面又会被 FileProvider 拒');
    });
  });
}
