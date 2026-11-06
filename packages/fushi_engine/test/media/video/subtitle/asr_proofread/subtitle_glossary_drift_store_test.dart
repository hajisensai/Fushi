import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary_drift_store.dart';
import 'package:test/test.dart';

void main() {
  late FushiDatabase db;
  int now = 1000;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    now = 1000;
  });
  tearDown(() => db.close());

  SubtitleGlossaryDriftStore store() =>
      SubtitleGlossaryDriftStore(db, now: () => now);

  test('没有行时 load 返回 null', () async {
    expect(await store().load('collection:1'), isNull);
  });

  test('save → load 往返整份专名表，上提列与 JSON 同源', () async {
    const SubtitleGlossary glossary = SubtitleGlossary(
      entries: <SubtitleGlossaryEntry>[
        SubtitleGlossaryEntry(
          ja: '平沢唯',
          reading: 'ひらさわゆい',
          kind: '人名',
          misrecognitions: <String>['平沢由衣'],
          userEdited: true,
        ),
        SubtitleGlossaryEntry(ja: '桜が丘高校', kind: '地名'),
      ],
      sourceFingerprint: 'fp-1',
      generatedAt: 500,
      userEditedAt: 900,
    );
    await store().save('collection:1', glossary);

    final SubtitleGlossary? loaded = await store().load('collection:1');
    expect(loaded, isNotNull);
    expect(loaded!.encode(), glossary.encode());
    expect(loaded.entries.first.userEdited, isTrue);
    expect(loaded.entries.first.misrecognitions, <String>['平沢由衣']);

    final VideoSubtitleGlossaryRow row = (await db.getVideoSubtitleGlossary(
      'collection:1',
    ))!;
    expect(row.sourceFingerprint, 'fp-1');
    expect(row.userEditedAt, 900);
    expect(row.updatedAt, 1000, reason: 'updated_at 取写入时刻，不取 JSON');
  });

  test('再次 save 整行覆盖：userEditedAt 跟着 glossary 走，updated_at 刷新', () async {
    await store().save(
      'work:7',
      const SubtitleGlossary(
        entries: <SubtitleGlossaryEntry>[SubtitleGlossaryEntry(ja: 'A')],
        userEditedAt: 900,
      ),
    );
    now = 2000;
    await store().save(
      'work:7',
      const SubtitleGlossary(
        entries: <SubtitleGlossaryEntry>[SubtitleGlossaryEntry(ja: 'B')],
        sourceFingerprint: 'fp-2',
      ),
    );
    final VideoSubtitleGlossaryRow row = (await db.getVideoSubtitleGlossary(
      'work:7',
    ))!;
    expect(row.userEditedAt, isNull);
    expect(row.sourceFingerprint, 'fp-2');
    expect(row.updatedAt, 2000);
    expect((await store().load('work:7'))!.entries.single.ja, 'B');
    // 键互不干扰。
    expect(await store().load('work:8'), isNull);
  });

  test('库里 JSON 坏了不吞成 null（否则会被当成从未生成而覆盖用户编辑）', () async {
    await db.upsertVideoSubtitleGlossary(
      VideoSubtitleGlossariesCompanion.insert(
        workKey: 'collection:9',
        glossaryJson: '{not json',
        updatedAt: 1,
      ),
    );
    expect(() => store().load('collection:9'), throwsFormatException);
  });
}
