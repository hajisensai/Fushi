import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// BUG-1265 守卫：AnkiConnect 制卡时**取不到词典媒体（外字 gaiji / 义项内嵌图）
/// 必须降级这一条，绝不能把整张卡拖垮**。
///
/// 用户报错：
/// ```
/// Anki.mineEntry  FileSystemException: Dictionary media file is missing,
///   path = '…/Temp/anki-media/hibiki_dict_<sha1>.svg'
///   AnkiConnectRepository._storeDictionaryMedia (…:1635)
/// ```
/// 卡片一张都建不出来。
///
/// 根因两层：
/// 1. 写入方 `writeDictionaryMediaCache`（主 app）**按设计就是尽力而为**：FushiDicts
///    未初始化 / `getMediaFile` 取不到字节（分卷 MDD 未挂载、词典里本就没这个资源、
///    词典删除重导）/ 写盘失败，三种情况都跳过不落盘，契约是「该条退回 alt 文本，
///    不阻断制卡」。
/// 2. 读取方 `AnkiConnectRepository._storeDictionaryMedia` 却在文件缺失时
///    `throw FileSystemException`，抛穿 `Future.wait` → `_renderMinedFields` →
///    `mineEntry`，整次制卡失败。commit 35e8c96b5「require media before adding
///    cards」把封面/句子音频的「缺媒体就别建卡」策略**误扫**到了装饰性词典媒体上。
///    AnkiDroid `_addDictionaryMedia` 与 AnkiMobile `_dictionaryMediaUrl` 一直是
///    返回 null 优雅降级，只有 AnkiConnect 破了共享契约
///    （`buildDictionaryMediaTags` 收的就是 `Future<String?>`）。
///
/// 本测锁死修复后的三条边界：缺媒体只降级这一条；能取到的照常嵌入（混排时不被邻居
/// 拖累）；封面/句子音频缺失**仍然**中止制卡（两套策略故意不同，别再合并）。
void main() {
  const String dictName = '明鏡国語辞典 第三版';
  const String gaijiPath = 'gaiji/hibiki_bug1264.svg';
  const String placeholder = 'hoshi_dict_0.svg';
  const String secondGaijiPath = 'gaiji/hibiki_bug1264_second.svg';
  const String secondPlaceholder = 'hoshi_dict_1.svg';

  final String cacheDir = ankiDictionaryMediaCacheDirPath();
  final String cachedName =
      ankiDictionaryMediaCacheFilename(dictName, gaijiPath);
  final String secondCachedName =
      ankiDictionaryMediaCacheFilename(dictName, secondGaijiPath);

  late Directory tempDir;
  late File gif;

  /// 制卡负载：义项 HTML 里带一个未替换的占位符 `<img src="hoshi_dict_0.svg">`，
  /// 并在 dictionaryMedia 登记它——与 popup.js 真实产出的形状一致。
  String payloadWith(List<({String path, String filename})> media) {
    final String glossaryImgs = media
        .map((m) => '<img class=\\"gloss-image\\" src=\\"${m.filename}\\">')
        .join();
    final String mediaJson = media
        .map((m) =>
            '{\\"dictionary\\":\\"$dictName\\",\\"path\\":\\"${m.path}\\",'
            '\\"filename\\":\\"${m.filename}\\"}')
        .join(',');
    return '{"expression":"言葉",'
        '"glossary":"$glossaryImgs意味",'
        '"dictionaryMedia":"[$mediaJson]"}';
  }

  AnkiSettings settings() => AnkiSettings(
        selectedDeckId: 1,
        selectedNoteTypeId: 2,
        availableDecks: const <AnkiDeck>[AnkiDeck(id: 1, name: 'Mining')],
        availableNoteTypes: const <AnkiNoteType>[
          AnkiNoteType(
            id: 2,
            name: 'Hibiki',
            fields: <String>['Expression', 'Meaning', 'Picture'],
          ),
        ],
        fieldMappings: const <String, String>{
          'Expression': '{expression}',
          'Meaning': '{glossary}',
          'Picture': '{card-image}',
        },
        allowDupes: true,
      );

  void removeCached() {
    for (final String name in <String>[cachedName, secondCachedName]) {
      final File f = File('$cacheDir/$name');
      if (f.existsSync()) f.deleteSync();
    }
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('hibiki_bug1264');
    gif = File('${tempDir.path}/cover.gif')
      ..writeAsBytesSync(<int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);
    removeCached();
  });

  tearDown(() {
    removeCached();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('词典媒体缓存缺失：卡片照常创建，只有这一条媒体降级', () async {
    final service = _RecordingAnkiConnectService();
    final repo = _ConfiguredAnkiConnectRepository(
      service: service,
      settings: settings(),
    );

    final MineOutcome outcome = await repo.mineEntry(
      rawPayloadJson: payloadWith(
        <({String path, String filename})>[
          (path: gaijiPath, filename: placeholder),
        ],
      ),
      context: AnkiMiningContext(
        sentence: 'これは言葉です。',
        coverPath: gif.path,
      ),
    );

    expect(outcome.result, MineResult.success,
        reason: '一个取不到字节的外字不得让整次制卡失败（BUG-1265）');
    expect(service.addedFields, hasLength(1), reason: 'addNote 必须真的被调用，卡片要落地');
    // 这条媒体降级：占位符保持原样（等价于 alt 文本），不会指向不存在的 Anki 媒体。
    expect(service.addedFields.single['Meaning'], contains(placeholder));
    expect(service.addedFields.single['Meaning'], contains('意味'));
    expect(
      service.storedMedia.map((e) => e.filename),
      isNot(contains(cachedName)),
      reason: '缺失的词典媒体不该被上传',
    );
    // 封面这类必需媒体不受影响，照常上传。
    expect(
      service.storedMedia.where((e) => e.filename.startsWith('hibiki_cover_')),
      hasLength(1),
    );
  });

  test('混排时：能取到的外字照常嵌入，取不到的那条单独降级', () async {
    Directory(cacheDir).createSync(recursive: true);
    File('$cacheDir/$cachedName').writeAsBytesSync(
      '<svg xmlns="http://www.w3.org/2000/svg"/>'.codeUnits,
    );

    final service = _RecordingAnkiConnectService();
    final repo = _ConfiguredAnkiConnectRepository(
      service: service,
      settings: settings(),
    );

    final MineOutcome outcome = await repo.mineEntry(
      rawPayloadJson: payloadWith(
        <({String path, String filename})>[
          (path: gaijiPath, filename: placeholder),
          // 第二条没有缓存文件：以前它会把第一条也一起拖垮。
          (path: secondGaijiPath, filename: secondPlaceholder),
        ],
      ),
      context: const AnkiMiningContext(sentence: 'これは言葉です。'),
    );

    expect(outcome.result, MineResult.success);
    final String meaning = service.addedFields.single['Meaning']!;
    expect(meaning, contains(cachedName), reason: '有缓存的那条外字必须被替换成真实媒体文件名');
    expect(meaning, isNot(contains(placeholder)));
    expect(meaning, contains(secondPlaceholder),
        reason: '缺失的那条保持占位符（降级），不影响邻居');
    expect(
      service.storedMedia.map((e) => e.filename),
      contains(cachedName),
    );
  });

  test('对比组：封面缺失仍然中止制卡（两套媒体策略故意不同，别再合并）', () async {
    final service = _RecordingAnkiConnectService();
    final repo = _ConfiguredAnkiConnectRepository(
      service: service,
      settings: settings(),
    );

    final MineOutcome outcome = await repo.mineEntry(
      rawPayloadJson: payloadWith(const <({String path, String filename})>[]),
      context: AnkiMiningContext(
        sentence: 'これは言葉です。',
        coverPath: '${tempDir.path}/does_not_exist.gif',
      ),
    );

    expect(outcome.result, MineResult.error,
        reason: '封面/句子音频缺失的卡片没有价值，必须继续拦住（35e8c96b5 的本意）');
    expect(service.addedFields, isEmpty);
  });
}

class _ConfiguredAnkiConnectRepository extends AnkiConnectRepository {
  _ConfiguredAnkiConnectRepository({
    required AnkiConnectService service,
    required this.settings,
  }) : super(service: service);

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}

class _RecordingAnkiConnectService extends AnkiConnectService {
  _RecordingAnkiConnectService({String host = 'localhost'}) : super(host: host);

  final List<Map<String, String>> addedFields = <Map<String, String>>[];
  final List<({String filename, String? data, String? path})> storedMedia =
      <({String filename, String? data, String? path})>[];
  final Set<String> existingMedia = <String>{};
  final List<String> deletedMedia = <String>[];

  @override
  Future<bool> mediaFileExists(String filename) async =>
      existingMedia.contains(filename);

  @override
  Future<void> storeMediaFile({
    required String filename,
    String? data,
    String? path,
  }) async {
    storedMedia.add((filename: filename, data: data, path: path));
    existingMedia.add(filename);
  }

  @override
  Future<void> deleteMediaFile(String filename) async {
    deletedMedia.add(filename);
    existingMedia.remove(filename);
  }

  @override
  Future<int?> addNote({
    required String deckName,
    required String modelName,
    required Map<String, String> fields,
    List<String>? tags,
    Map<String, String>? mediaFiles,
    bool allowDuplicate = false,
    AnkiDuplicateScope duplicateScope = AnkiDuplicateScope.deck,
  }) async {
    addedFields.add(Map<String, String>.from(fields));
    return addedFields.length;
  }
}
