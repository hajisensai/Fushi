import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// galgame「视频片段」封面：mp4 / webm 的封面引用必须渲染成 `[sound:]`（Anki 桌面
/// 用 mpv 播、AnkiDroid 用内置 VideoView 播），图片仍是 `<img src>`。两 backend 都经
/// [coverMediaRef] 一处分流——本测既钉纯函数，也走完整 mineEntry 链证明两端真用了它。
void main() {
  group('coverMediaRef', () {
    test('图片扩展名 → <img src>', () {
      expect(
        coverMediaRef('fushi_cover_abc.jpg'),
        '<img src="fushi_cover_abc.jpg">',
      );
      expect(
        coverMediaRef('fushi_cover_abc.png'),
        '<img src="fushi_cover_abc.png">',
      );
      expect(
        coverMediaRef('fushi_cover_abc.gif'),
        '<img src="fushi_cover_abc.gif">',
      );
      expect(
        coverMediaRef('fushi_cover_abc.avif'),
        '<img src="fushi_cover_abc.avif">',
      );
    });

    test('mp4 / webm → [sound:]（大小写不敏感）', () {
      expect(
        coverMediaRef('fushi_cover_abc.mp4'),
        '[sound:fushi_cover_abc.mp4]',
      );
      expect(
        coverMediaRef('fushi_cover_abc.MP4'),
        '[sound:fushi_cover_abc.MP4]',
      );
      expect(coverMediaRef('clip.webm'), '[sound:clip.webm]');
    });

    test('无扩展名 / 未知扩展名仍按图片处理', () {
      expect(coverMediaRef('cover'), '<img src="cover">');
      expect(coverMediaRef('cover.bin'), '<img src="cover.bin">');
    });

    test('<img> 的 src 做 HTML 转义', () {
      expect(coverMediaRef('a"b.jpg'), '<img src="a&quot;b.jpg">');
    });
  });

  // 最小 mp4：ftyp box（内容不需要真能播，两端都只按扩展名与字节哈希落媒体）。
  final List<int> mp4Bytes = <int>[
    0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, //
    0x69, 0x73, 0x6F, 0x6D, 0x00, 0x00, 0x02, 0x00, //
    0x69, 0x73, 0x6F, 0x6D, 0x6D, 0x70, 0x34, 0x31, //
  ];

  const AnkiSettings settings = AnkiSettings(
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
  const String payload = '{"expression":"言葉"}';

  late Directory dir;
  late File mp4;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('hibiki_cover_media_ref');
    mp4 = File('${dir.path}/external_window.mp4')..writeAsBytesSync(mp4Bytes);
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('AnkiConnect：mp4 封面落卡为 [sound:fushi_cover_<sha>.mp4]', () async {
    final _RecordingAnkiConnectService service = _RecordingAnkiConnectService();
    final _ConfiguredAnkiConnectRepository repo =
        _ConfiguredAnkiConnectRepository(service: service, settings: settings);
    final MineOutcome outcome = await repo.mineEntry(
      rawPayloadJson: payload,
      context: AnkiMiningContext(
        sentence: 'これは言葉です。',
        coverPath: mp4.path,
        source: AnkiMiningSource.game,
      ),
    );
    expect(outcome.result, MineResult.success);
    expect(
      service.addedFields.single['Picture'],
      matches(RegExp(r'^\[sound:fushi_cover_[0-9a-f]{64}\.mp4\]$')),
    );
  });

  test('AnkiDroid：mp4 封面落卡为 [sound:fushi_cover_<sha>.mp4]', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const MethodChannel channel = MethodChannel('app.fushi.reader/anki');
    final List<List<String>> addedFieldArrays = <List<String>>[];
    final List<String> mimeTypes = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      switch (call.method) {
        case 'requestAnkidroidPermissions':
          return true;
        case 'checkForDuplicates':
          return false;
        case 'addFileToMedia':
          final Map<String, dynamic> args = Map<String, dynamic>.from(
            call.arguments as Map,
          );
          mimeTypes.add(args['mimeType'] as String? ?? '');
          return args['preferredName'] as String?;
        case 'addNote':
          final Map<String, dynamic> args = Map<String, dynamic>.from(
            call.arguments as Map,
          );
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

    final MineOutcome outcome =
        await _ConfiguredAnkiRepository(settings).mineEntry(
      rawPayloadJson: payload,
      context: AnkiMiningContext(
        sentence: 'これは言葉です。',
        coverPath: mp4.path,
        source: AnkiMiningSource.game,
      ),
    );
    expect(outcome.result, MineResult.success);
    expect(addedFieldArrays, hasLength(1));
    expect(
      addedFieldArrays.single[1],
      matches(RegExp(r'^\[sound:fushi_cover_[0-9a-f]{64}\.mp4\]$')),
    );
    expect(mimeTypes, contains('video/mp4'));
  });
}

class _RecordingAnkiConnectService extends AnkiConnectService {
  _RecordingAnkiConnectService() : super(host: 'localhost');

  final List<Map<String, String>> addedFields = <Map<String, String>>[];
  final Set<String> existingMedia = <String>{};

  @override
  Future<bool> mediaFileExists(String filename) async =>
      existingMedia.contains(filename);

  @override
  Future<void> storeMediaFile({
    required String filename,
    String? data,
    String? path,
  }) async {
    existingMedia.add(filename);
  }

  @override
  Future<void> deleteMediaFile(String filename) async {
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
