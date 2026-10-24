// 互联主机**替别的设备**制卡（收转发 / 浏览器扩展）遵守本机挖词目标：
// `hostMiningAnkiRepositoryProvider` → `AppModel.hostMiningAnkiRepository` →
// `_AppModelRemoteLookupService`。目标是 Fushi 复习时落复习、不写 Anki；目标是 Anki
// （或复习模块关着）时与原来一样直接写本机 Anki。
//
// 装配与 main.dart 同形：真 ProviderContainer 里读 provider，AppModel 的委托指向它，
// 再经 AppModel 的生产工厂拿互联服务——只把平台 Anki 后端与复习库换成内存替身。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_mining_target.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/sync/forwarded_mine_payload.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi_srs/fushi_srs.dart';

import '../helpers/fake_platform_services.dart';
import 'srs_test_support.dart';

/// 主机本机的 Anki 后端替身：记下每一次写入 / 查重，用来断言「写没写 Anki」。
class _RecordingAnki extends BaseAnkiRepository {
  final List<String> minedPayloads = <String>[];
  int duplicateChecks = 0;
  int sourceReads = 0;

  @override
  Future<AnkiSettings> loadSettings() async =>
      const AnkiSettings(tags: 'host-tag');

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      throw UnimplementedError();

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    minedPayloads.add(rawPayloadJson);
    return const MineOutcome.success(deckName: 'Host Anki deck');
  }

  @override
  Future<bool> isDuplicate(String expression, String reading) async {
    duplicateChecks++;
    return false;
  }

  @override
  Future<AnkiSourceNote?> readSourceNote(String sourceId) async {
    sourceReads++;
    return null;
  }

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;

  @override
  Future<bool> createDeck(String name) async => false;
}

class _TargetAppModel extends AppModel {
  _TargetAppModel(super.platformServices, this._target);

  final SrsMiningTarget _target;

  @override
  SrsMiningTarget get srsMiningTarget => _target;
}

Map<String, String> _fields(String expression, String reading) =>
    <String, String>{
      'expression': expression,
      'reading': reading,
      'glossary': '<ol><li>snow</li></ol>',
      'glossaryFirst': '<ol><li>snow</li></ol>',
    };

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late SrsDbStore store;
  late SrsMediaStore media;
  late _RecordingAnki anki;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('fushi_host_mining_');
    (db, store) = await openSrsTestStore();
    media = SrsMediaStore(Directory('${tmp.path}/srs_media/$kSrsTestProfile'));
    anki = _RecordingAnki();
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  /// 与 main.dart 同一接线：AppModel 的 `hostMiningRepositoryReader` 读根容器里的
  /// `hostMiningAnkiRepositoryProvider`，互联服务由 AppModel 的生产工厂给出。
  AppModel wiredAppModel({
    required bool srsEnabled,
    required SrsMiningTarget target,
  }) {
    final ProviderContainer c = ProviderContainer(
      overrides: <Override>[
        platformServicesProvider.overrideWithValue(
          fakePlatformServices(createAnkiRepository: () => anki),
        ),
        appProvider.overrideWith(
          (Ref ref) => _TargetAppModel(
            fakePlatformServices(createAnkiRepository: () => anki),
            target,
          ),
        ),
        srsModuleEnabledProvider.overrideWithValue(srsEnabled),
        srsStoreProvider.overrideWith((Ref ref) async => store),
        srsMediaStoreProvider.overrideWith((Ref ref) async => media),
      ],
    );
    addTearDown(c.dispose);
    final AppModel app = c.read(appProvider);
    app.hostMiningRepositoryReader = () =>
        c.read(hostMiningAnkiRepositoryProvider);
    return app;
  }

  Future<SrsTermStatus?> srsStatus(String expression, String reading) async {
    final Map<String, SrsTermStatus> hit = await store.lookupTermStatus(
      <SrsTermQuery>[SrsTermQuery(expression, reading)],
    );
    return hit[expression];
  }

  ForwardedMinePayload forwarded(String expression, String reading) =>
      ForwardedMinePayload(
        rawPayloadJson: jsonEncode(_fields(expression, reading)),
        sentence: '雪が降る。',
        documentTitle: 'Snow Country',
        coverBytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
        coverExt: 'png',
      );

  group('目标 = Fushi 复习', () {
    test('mineEntry（浏览器扩展 / 远程查词制卡）落复习、不写 Anki', () async {
      final FushiRemoteMiningService service = wiredAppModel(
        srsEnabled: true,
        target: SrsMiningTarget.srs,
      ).createRemoteMiningService();

      final RemoteMineResult out = await service.mineEntry(
        fields: _fields('雪', 'ゆき'),
        sentence: '雪が降る。',
      );

      expect(out.result, MineResult.success.name);
      expect(anki.minedPayloads, isEmpty, reason: '目标是复习时不得写主机 Anki');
      final SrsTermStatus? hit = await srsStatus('雪', 'ゆき');
      expect(hit, isNotNull, reason: '卡应落进主机的 Fushi 复习');
      expect(hit!.cardCount, greaterThan(0));
    });

    test('mineForwarded（对端「制卡到主机」）落复习、媒体进复习媒体库、不写 Anki', () async {
      final FushiRemoteMiningService service = wiredAppModel(
        srsEnabled: true,
        target: SrsMiningTarget.srs,
      ).createRemoteMiningService();

      final RemoteMineResult out = await service.mineForwarded(
        forwarded('雨', 'あめ'),
      );

      expect(out.result, MineResult.success.name);
      expect(anki.minedPayloads, isEmpty);
      final SrsTermStatus? hit = await srsStatus('雨', 'あめ');
      expect(hit, isNotNull);
      final SrsNoteView note = (await store.note(hit!.noteId))!;
      final String coverName = SrsMediaStore.contentName('x.png', <int>[
        1,
        2,
        3,
        4,
      ]);
      // 对端发来的封面字节在主机落成临时文件，再被复习层按内容哈希收进媒体库。
      expect(
        note.fields.values.any((String v) => v.contains(coverName)),
        isTrue,
      );
      expect(await media.load(coverName), <int>[1, 2, 3, 4]);
    });

    test('isDuplicate 与出处笔记先读复习，不问 Anki', () async {
      final AppModel app = wiredAppModel(
        srsEnabled: true,
        target: SrsMiningTarget.srs,
      );
      final FushiRemoteMiningService service = app.createRemoteMiningService();
      final String sourceId = CardSourceLink.newSourceId();
      final RemoteMineResult out = await service.mineForwarded(
        ForwardedMinePayload(
          rawPayloadJson: jsonEncode(_fields('風', 'かぜ')),
          sentence: '風が吹く。',
          documentTitle: 'Snow Country',
          source: AnkiMiningSource.book.name,
          sourceLink: CardSourceLink(
            kind: CardSourceKind.book,
            uid: 'book_1',
            sourceId: sourceId,
            chapterIndex: 3,
            charOffset: 120,
            charLength: 1,
            bookKey: 'Snow Country',
          ),
        ),
      );
      expect(out.result, MineResult.success.name);

      expect(await service.isDuplicate(expression: '風', reading: 'かぜ'), isTrue);
      expect(anki.duplicateChecks, 0);

      final FushiRemoteSourceNoteService notes =
          app.createRemoteLookupService() as FushiRemoteSourceNoteService;
      final AnkiSourceNote? note = await notes.readSourceNote(sourceId);
      expect(note, isNotNull, reason: '对端制进主机复习的卡，回到出处时从复习读');
      expect(note!.sourceId, sourceId);
      expect(anki.sourceReads, 0);
      // 复习里没有的出处（切换前制进 Anki 的卡）才回落去问 Anki——SRS 层的既定语义。
      expect(await notes.readSourceNote(CardSourceLink.newSourceId()), isNull);
      expect(anki.sourceReads, 1);
    });
  });

  group('目标 = Anki（与原行为一致）', () {
    for (final ({bool srsEnabled, SrsMiningTarget target}) c
        in <({bool srsEnabled, SrsMiningTarget target})>[
          (srsEnabled: true, target: SrsMiningTarget.anki),
          // 复习模块关着时偏好里的目标不起作用：链上根本没有 SRS 层。
          (srsEnabled: false, target: SrsMiningTarget.srs),
        ]) {
      test('srsEnabled=${c.srsEnabled} target=${c.target.name}：'
          'mineEntry / mineForwarded / isDuplicate 写的是本机 Anki，复习不动', () async {
        final AppModel app = wiredAppModel(
          srsEnabled: c.srsEnabled,
          target: c.target,
        );
        expect(app.hostMiningAnkiRepository, same(anki), reason: '裸本机后端');
        final FushiRemoteMiningService service = app
            .createRemoteMiningService();

        final RemoteMineResult a = await service.mineEntry(
          fields: _fields('雪', 'ゆき'),
          sentence: '雪が降る。',
        );
        final RemoteMineResult b = await service.mineForwarded(
          forwarded('雨', 'あめ'),
        );
        await service.isDuplicate(expression: '雪', reading: 'ゆき');

        expect(a.result, MineResult.success.name);
        expect(a.deckName, 'Host Anki deck');
        expect(b.result, MineResult.success.name);
        expect(anki.minedPayloads, hasLength(2));
        expect(
          (jsonDecode(anki.minedPayloads[0])
              as Map<String, Object?>)['expression'],
          '雪',
        );
        expect(
          (jsonDecode(anki.minedPayloads[1])
              as Map<String, Object?>)['expression'],
          '雨',
        );
        expect(anki.duplicateChecks, 1);
        expect(await srsStatus('雪', 'ゆき'), isNull);
        expect(await srsStatus('雨', 'あめ'), isNull);
      });
    }
  });
}
