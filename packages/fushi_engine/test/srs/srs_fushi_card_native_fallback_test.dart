import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_fushi_card_native_media.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';

const String kProfile = '01928c3e-0000-7000-8000-000000000003';

/// BUG（反馈 O5YDP27Xko，Android 复习卡整面 WebView）：内置 Fushi 卡片有修改记录后就冻成
/// 记录里的全文；内置模板之后再升级（a6acbfb4d8 区块自定义），冻住的旧版本在逐字比较下不再
/// 是「内置」，原生卡面整张静默回退 WebView，且不留任何原因。
///
/// 钉住两件事：① 历史内置版本（登记表 kFushiCardTemplateHistory）照样走原生；② 回退时
/// 带上卡在哪一道（[SrsCardNativeFallback]）。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  /// a6acbfb4d8 之前最后一版内置模板（f5ab1a649d），从 git 历史原样取出。
  String fixture(String file) => File(
    '${Directory.current.path}/test/srs/fixtures/fushi_card_f5ab1a649d/$file',
  ).readAsStringSync();
  final String oldFront = fixture('front.html');
  final String oldBack = fixture('back.html');
  final String oldCss = fixture('styling.css');

  final Map<String, String> fields = <String, String>{
    for (final String f in FushiCardNoteType.fields) f: '',
    'Term': '免許',
    'MainDefinition': '<ol><li>licence</li></ol>',
    'Media': '<img src="a.jpg">',
  };

  SrsFushiCardNativeProbe probe({
    String? builtinKey = kSrsBuiltinFushiCardKey,
    String? front,
    String? back,
    String? css,
    Map<String, String>? fieldsByName,
  }) => srsFushiCardNative(
    builtinKey: builtinKey,
    front: front ?? kFushiCardFrontTemplate,
    back: back ?? kFushiCardBackTemplate,
    css: css ?? kFushiCardStylingCss,
    fieldsByName: fieldsByName ?? fields,
    cardOrd: 0,
  );

  group('srsFushiCardNative', () {
    test('当前内置模板走原生、不带原因', () {
      final SrsFushiCardNativeProbe p = probe();
      expect(p.fallback, isNull);
      expect(p.native, isNotNull);
      expect(p.native!.css, kFushiCardStylingCss);
    });

    test('a6acbfb4d8 之前冻住的内置模板（f5ab1a649d）仍走原生，释义用当前样式', () {
      expect(fushiCardCssIsDefault(oldCss), isFalse, reason: '素材确是旧版样式');
      final SrsFushiCardNativeProbe p = probe(
        front: oldFront,
        back: oldBack,
        css: oldCss,
      );
      expect(p.fallback, isNull);
      expect(p.native!.front, kFushiCardDefaultFrontItems);
      expect(p.native!.back, kFushiCardDefaultBackItems);
      expect(
        p.native!.css,
        kFushiCardStylingCss,
        reason: '释义 HTML 按当前模板生成，样式必须是当前版',
      );
      expect(p.native!.definitions, contains('licence'));
    });

    test('那一版背面调过区块顺序（剪切挪位置）照样认出顺序', () {
      // 3f48498f85 起背面可调序：把图片整段挪到词条前面。
      const String picture =
          '{{#Media}}<figure class="fc-media {{Tags}}">{{Media}}</figure>{{/Media}}';
      expect(oldBack.contains(picture), isTrue);
      final String moved = oldBack
          .replaceFirst(picture, '')
          .replaceFirst(
            '<div class="fc-term">',
            '$picture<div class="fc-term">',
          );
      final SrsFushiCardNativeProbe p = probe(
        front: oldFront,
        back: moved,
        css: oldCss,
      );
      expect(p.fallback, isNull);
      expect(
        <Enum>[
          for (final FushiCardItem x in p.native!.back)
            (x as FushiCardBlockItem).block,
        ],
        <Enum>[
          FushiCardBlock.picture,
          FushiCardBlock.term,
          FushiCardBlock.reading,
          FushiCardBlock.sentence,
          FushiCardBlock.definitions,
          FushiCardBlock.frequency,
          FushiCardBlock.source,
        ],
      );
    });

    test('样式、正面骨架、背面骨架、媒体各改一处：给出对应原因', () {
      final SrsCardNativeFallback? css = probe(
        css: '$kFushiCardStylingCss\n.x { color: red; }',
      ).fallback;
      expect(css?.code, SrsCardNativeFallbackCode.cssModified);

      final SrsCardNativeFallback? front = probe(
        front: kFushiCardFrontTemplate.replaceFirst(
          '<div class="fc fc-front"',
          '<div class="fc fc-front mine"',
        ),
      ).fallback;
      expect(front?.code, SrsCardNativeFallbackCode.frontTemplate);
      expect(front?.detail, contains('mine'), reason: '带第一处差异附近的原文');

      final SrsCardNativeFallback? back = probe(
        back: kFushiCardBackTemplate.replaceFirst(
          '<script>',
          '<p>x</p><script>',
        ),
      ).fallback;
      expect(back?.code, SrsCardNativeFallbackCode.backTemplate);
      expect(back?.detail, contains('<p>x</p>'));

      final SrsCardNativeFallback? media = probe(
        fieldsByName: <String, String>{
          ...fields,
          'Media': '<img src="https://example.com/a.png">',
        },
      ).fallback;
      expect(media?.code, SrsCardNativeFallbackCode.media);
      expect(media?.detail, contains('https://example.com/a.png'));

      final SrsCardNativeFallback? text = probe(
        fieldsByName: <String, String>{...fields, 'Media': '<b>caption</b>'},
      ).fallback;
      expect(text?.code, SrsCardNativeFallbackCode.media);
      expect(text?.detail, contains('caption'));

      expect(
        probe(builtinKey: null).fallback?.code,
        SrsCardNativeFallbackCode.notBuiltin,
      );
    });

    test('媒体字段还是旧名（Picture）时同样判', () {
      final SrsCardNativeFallback? f = probe(
        fieldsByName: <String, String>{
          for (final MapEntry<String, String> e in fields.entries)
            if (e.key != 'Media') e.key: e.value,
          'Picture': '<img src="https://example.com/a.png">',
        },
      ).fallback;
      expect(f?.code, SrsCardNativeFallbackCode.media);
    });
  });

  group('renderCard', () {
    int t = DateTime.utc(2026, 11, 7, 12).millisecondsSinceEpoch;

    Future<SrsRenderedCard> render(SrsDbStore s) async {
      final String note = await s.createNote(
        noteTypeId: s.fushiCardNoteTypeId,
        fieldsById: <String, String>{
          srsFushiCardFieldId(kProfile, 'Expression'): '免許',
          srsFushiCardFieldId(kProfile, 'MainDefinition'):
              '<ol><li>licence</li></ol>',
        },
      );
      final SrsCardCacheRow card = (await s.cardsOfNote(note)).first;
      t += 1000;
      return (await s.renderCard(card.id))!;
    }

    test('冻住的旧版内置模板走原生；改过样式的带回退原因', () async {
      final SrsDbStore s = await openTestStore(
        profileUid: kProfile,
        deviceId: 'a',
        now: () => t++,
      );
      final String nt = s.fushiCardNoteTypeId;
      final SrsRenderedCard fresh = await render(s);
      expect(fresh.fushiCardDefinitions, isNotNull);
      expect(fresh.nativeFallback, isNull);

      // 写成修改记录（导入 / 同步 / 外观页都会这样冻住旧版本）。
      final SrsNoteTypeView type = (await s.noteType(nt))!;
      final Map<String, String> nameToId = <String, String>{
        for (final SrsFieldDef f in type.fields) f.name: f.id,
      };
      await s.saveTemplateEdits(
        nt,
        type.templates.single.id,
        front: templateNamesToIds(oldFront, nameToId),
        back: templateNamesToIds(oldBack, nameToId),
        css: oldCss,
      );
      final SrsRenderedCard frozen = await render(s);
      expect(frozen.nativeFallback, isNull);
      expect(frozen.fushiCardDefinitions, contains('licence'));
      expect(frozen.css, kFushiCardStylingCss);

      await s.saveTemplateEdits(
        nt,
        type.templates.single.id,
        css: '$oldCss\n.mine { color: red; }',
      );
      final SrsRenderedCard modified = await render(s);
      expect(modified.fushiCardDefinitions, isNull);
      expect(
        modified.nativeFallback?.code,
        SrsCardNativeFallbackCode.cssModified,
      );
    });
  });
}
