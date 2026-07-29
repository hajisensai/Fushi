import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

/// TODO-1298 端到端守卫：老 note-type 的 {book-cover} Picture 字段在视频制卡时也产 GIF。
///
/// 用户反馈「我卡组还是 book-cover，没变成 card-image，你不会让我手动改吧」——担心旧
/// 占位符 {book-cover} 在视频卡上不出图、必须手改成新键 {card-image}。事实是三键
/// （{card-image} / {book-cover} / {video-clip}）都读同一个 context.coverPath，视频
/// 制卡时 coverPath 就是 GIF/降级帧（immersion_mining_engine），两 backend 都把
/// coverPath 落盘成媒体引用后回填同一 coverPath 字段再渲染——按值不按名，故三键等效。
///
/// 已有 handlebar_card_image_test / handlebar_video_clip_test 只测孤立 renderer（手动
/// 构造 <img src> context）。本测补上缺失的一环：走完整 mineEntry 落卡链（真 .gif
/// → 存媒体 → 渲染字段），断言映射到 {book-cover} 的 Picture 字段真拿到
/// <img src="hibiki_cover_<sha>.gif">，且与 {card-image} / {video-clip} 逐字节相同。
/// 撤掉三键任一别名、或让 backend 按 handlebar 名特判封面 → 本测转红。
void main() {
  final List<int> gifBytes = <int>[
    0x47,
    0x49,
    0x46,
    0x38,
    0x39,
    0x61,
    0x01,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x00,
  ];

  late Directory dir;
  late File gif;
  late File audio;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('hibiki_card_image_e2e');
    gif = File('${dir.path}/immersion_clip.gif')..writeAsBytesSync(gifBytes);
    audio = File('${dir.path}/sentence.aac')
      ..writeAsBytesSync(<int>[0x41, 0x44, 0x54, 0x53]);
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  AnkiSettings settingsWithPicture(String pictureHandlebar) => AnkiSettings(
        selectedDeckId: 1,
        selectedNoteTypeId: 2,
        availableDecks: const <AnkiDeck>[AnkiDeck(id: 1, name: 'Mining')],
        availableNoteTypes: const <AnkiNoteType>[
          AnkiNoteType(
            id: 2,
            name: 'Hibiki',
            fields: <String>['Expression', 'Picture'],
          ),
        ],
        fieldMappings: <String, String>{
          'Expression': '{expression}',
          'Picture': pictureHandlebar,
        },
        allowDupes: true,
      );

  const String payload = '{"expression":"言葉"}';

  group('AnkiConnect video mining: {book-cover} Picture 也产 GIF (TODO-1298)',
      () {
    Future<String?> pictureFor(String pictureHandlebar) async {
      final service = _RecordingAnkiConnectService();
      final repo = _ConfiguredAnkiConnectRepository(
        service: service,
        settings: settingsWithPicture(pictureHandlebar),
      );
      final outcome = await repo.mineEntry(
        rawPayloadJson: payload,
        context: AnkiMiningContext(
          sentence: 'これは言葉です。',
          coverPath: gif.path,
          source: AnkiMiningSource.video,
        ),
      );
      expect(outcome.result, MineResult.success);
      expect(service.addedFields, hasLength(1));
      return service.addedFields.single['Picture'];
    }

    test('{book-cover}（旧默认）在视频卡上拿到 GIF <img>，不是空', () async {
      final String? picture = await pictureFor('{book-cover}');
      expect(picture, isNotNull);
      expect(
        picture,
        matches(RegExp(r'^<img src="hibiki_cover_[0-9a-f]{64}\.gif">$')),
        reason: '老 {book-cover} 模板视频制卡必须产 GIF <img>，否则用户被迫手改',
      );
    });

    test('{card-image} / {book-cover} / {video-clip} 三键在视频卡上逐字节相同', () async {
      final String? cardImage = await pictureFor('{card-image}');
      final String? bookCover = await pictureFor('{book-cover}');
      final String? videoClip = await pictureFor('{video-clip}');
      expect(cardImage, isNotNull);
      expect(bookCover, cardImage);
      expect(videoClip, cardImage);
    });

    test('无封面（coverPath=null）时 Picture 字段留空（书内无封面不塞坏图）', () async {
      final service = _RecordingAnkiConnectService();
      final repo = _ConfiguredAnkiConnectRepository(
        service: service,
        settings: settingsWithPicture('{book-cover}'),
      );
      final outcome = await repo.mineEntry(
        rawPayloadJson: payload,
        context: const AnkiMiningContext(sentence: 'これは言葉です。'),
      );
      expect(outcome.result, MineResult.success);
      expect(service.addedFields.single.containsKey('Picture'), isFalse);
    });

    test('本机 Anki 先按 path 上传 GIF，确认成功后才 addNote', () async {
      final service = _RecordingAnkiConnectService();
      final repo = _ConfiguredAnkiConnectRepository(
        service: service,
        settings: settingsWithPicture('{card-image}'),
      );

      final outcome = await repo.mineEntry(
        rawPayloadJson: payload,
        context: AnkiMiningContext(
          sentence: 'これは言葉です。',
          coverPath: gif.path,
        ),
      );

      expect(outcome.result, MineResult.success);
      expect(service.storedMedia, hasLength(1));
      expect(service.storedMedia.single.path, gif.absolute.path);
      expect(service.storedMedia.single.data, isNull,
          reason: '本机 Anki 不应把 GIF 放大成 base64 JSON');
      expect(service.addedFields, hasLength(1));
    });

    test('远程 AnkiConnect 不可读本机 path，保留 base64 上传', () async {
      final service = _RecordingAnkiConnectService(host: '192.0.2.10');
      final repo = _ConfiguredAnkiConnectRepository(
        service: service,
        settings: settingsWithPicture('{card-image}'),
      );

      final outcome = await repo.mineEntry(
        rawPayloadJson: payload,
        context: AnkiMiningContext(
          sentence: 'これは言葉です。',
          coverPath: gif.path,
        ),
      );

      expect(outcome.result, MineResult.success);
      expect(service.storedMedia.single.path, isNull);
      expect(service.storedMedia.single.data, isNotEmpty);
    });

    test('GIF 上传失败时不调用 addNote，不再创建无图卡', () async {
      final service = _FailingMediaAnkiConnectService();
      final repo = _ConfiguredAnkiConnectRepository(
        service: service,
        settings: settingsWithPicture('{card-image}'),
      );

      final outcome = await repo.mineEntry(
        rawPayloadJson: payload,
        context: AnkiMiningContext(
          sentence: 'これは言葉です。',
          coverPath: gif.path,
        ),
      );

      expect(outcome.result, MineResult.error);
      expect(service.addedFields, isEmpty, reason: '媒体没有确认上传成功前绝不能 addNote');
    });

    test('并行媒体一路失败时回滚本次新写文件，且不调用 addNote', () async {
      final service = _CoordinatedFailingMediaAnkiConnectService();
      final repo = _ConfiguredAnkiConnectRepository(
        service: service,
        settings: settingsWithPicture('{card-image}'),
      );

      final outcome = await repo.mineEntry(
        rawPayloadJson: payload,
        context: AnkiMiningContext(
          sentence: 'これは言葉です。',
          coverPath: gif.path,
          sasayakiAudioPath: audio.path,
        ),
      );

      expect(outcome.result, MineResult.error);
      expect(service.addedFields, isEmpty);
      expect(
        service.deletedMedia.toSet(),
        service.storedMedia.map((entry) => entry.filename).toSet(),
        reason: '一路响应丢失时也须补偿删除本次可能已提交的全部新媒体',
      );
    });

    test('补偿回滚绝不删除制卡前已存在的共享哈希媒体', () async {
      final service = _CoordinatedFailingMediaAnkiConnectService(
        preexistingCover: true,
      );
      final repo = _ConfiguredAnkiConnectRepository(
        service: service,
        settings: settingsWithPicture('{card-image}'),
      );

      final outcome = await repo.mineEntry(
        rawPayloadJson: payload,
        context: AnkiMiningContext(
          sentence: 'これは言葉です。',
          coverPath: gif.path,
          sasayakiAudioPath: audio.path,
        ),
      );

      expect(outcome.result, MineResult.error);
      final String coverFilename = service.storedMedia
          .singleWhere((entry) => entry.filename.startsWith('hibiki_cover_'))
          .filename;
      expect(service.deletedMedia, isNot(contains(coverFilename)),
          reason: '内容哈希同名文件可能被旧卡共享，若原先存在绝不能补偿删除');
      expect(
        service.deletedMedia,
        contains(
          service.storedMedia
              .singleWhere(
                  (entry) => entry.filename.startsWith('hibiki_audio_'))
              .filename,
        ),
      );
      expect(service.addedFields, isEmpty);
    });
  });

  group('AnkiDroid video mining: {book-cover} Picture 也产 GIF (TODO-1298)', () {
    Future<String?> pictureFor(String pictureHandlebar) async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const MethodChannel channel = MethodChannel('app.hibiki.reader/anki');
      final List<List<String>> addedFieldArrays = <List<String>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        switch (call.method) {
          case 'checkForDuplicates':
            return false;
          case 'addFileToMedia':
            final args = Map<String, dynamic>.from(call.arguments as Map);
            return args['preferredName'] as String?;
          case 'addNote':
            final args = Map<String, dynamic>.from(call.arguments as Map);
            addedFieldArrays.add(List<String>.from(args['fields'] as List));
            return true;
          default:
            fail('Unexpected AnkiDroid channel call: ${call.method}');
        }
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final repo =
          _ConfiguredAnkiRepository(settingsWithPicture(pictureHandlebar));
      final outcome = await repo.mineEntry(
        rawPayloadJson: payload,
        context: AnkiMiningContext(
          sentence: 'これは言葉です。',
          coverPath: gif.path,
          source: AnkiMiningSource.video,
        ),
      );
      expect(outcome.result, MineResult.success);
      expect(addedFieldArrays, hasLength(1));
      return addedFieldArrays.single[1];
    }

    test('{book-cover}（旧默认）在视频卡上拿到 GIF <img>，不是空', () async {
      final String? picture = await pictureFor('{book-cover}');
      expect(picture, isNotNull);
      expect(picture!,
          matches(RegExp(r'^<img src="hibiki_cover_[0-9a-f]{64}\.gif">$')));
    });

    test('三键在视频卡上逐字节相同（与 AnkiConnect 对称）', () async {
      final String? cardImage = await pictureFor('{card-image}');
      final String? bookCover = await pictureFor('{book-cover}');
      final String? videoClip = await pictureFor('{video-clip}');
      expect(cardImage, isNotNull);
      expect(bookCover, cardImage);
      expect(videoClip, cardImage);
    });
  });
}

class _RecordingAnkiConnectService extends AnkiConnectService {
  _RecordingAnkiConnectService({
    String host = 'localhost',
    Set<String>? existingMedia,
  })  : existingMedia = existingMedia ?? <String>{},
        super(host: host);

  final List<Map<String, String>> addedFields = <Map<String, String>>[];
  final List<({String filename, String? data, String? path})> storedMedia =
      <({String filename, String? data, String? path})>[];
  final Set<String> existingMedia;
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

class _FailingMediaAnkiConnectService extends _RecordingAnkiConnectService {
  @override
  Future<void> storeMediaFile({
    required String filename,
    String? data,
    String? path,
  }) {
    throw TimeoutException('simulated media upload timeout');
  }
}

class _CoordinatedFailingMediaAnkiConnectService
    extends _RecordingAnkiConnectService {
  _CoordinatedFailingMediaAnkiConnectService({
    this.preexistingCover = false,
  });

  final bool preexistingCover;
  final Completer<void> _coverStored = Completer<void>();

  @override
  Future<bool> mediaFileExists(String filename) async =>
      preexistingCover && filename.startsWith('hibiki_cover_');

  @override
  Future<void> storeMediaFile({
    required String filename,
    String? data,
    String? path,
  }) async {
    if (filename.startsWith('hibiki_audio_')) {
      await _coverStored.future;
      await super.storeMediaFile(filename: filename, data: data, path: path);
      throw TimeoutException('simulated lost audio upload response');
    }
    await super.storeMediaFile(filename: filename, data: data, path: path);
    if (!_coverStored.isCompleted) _coverStored.complete();
  }
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

class _ConfiguredAnkiRepository extends AnkiRepository {
  _ConfiguredAnkiRepository(this.settings);

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}
