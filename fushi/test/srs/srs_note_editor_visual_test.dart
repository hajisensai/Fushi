// 笔记编辑页的可视化字段编辑：类型判据与标记纯函数、富文本控制器，以及整页上的
// 原样往返 / 加粗写入 / 图片入媒体库 / [sound:] 解析与删除 / HTML 源码切换 / 改读音。
//
// 内存库 + 确定性假排程内核；卡面（结构化预览）经 srsCardFaceBuilderProvider 换成纯文本。
// 数据库与文件读写一律放 tester.runAsync（fake zone 里 await 真异步会挂死）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_editors.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_rich_text_controller.dart';
import 'package:fushi/src/srs/srs_field_markup.dart';
import 'package:fushi/src/srs/srs_fushi_card_fields.dart' show srsSoundNames;
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

/// Yomitan 结构化释义（class / style / data-dictionary 都要原样留下）。
const String _kGlossary =
    '<div style="text-align: left;" class="yomitan-glossary"><ol>'
    '<li data-dictionary="大辞林"><i>(大辞林)</i> '
    '<span class="gloss-sc-span" style="font-weight: bold; color: #c00;">かよう</span>'
    '</li></ol></div>';
const String _kSentence = '毎日図書館に<strong>通って</strong>います&amp;。';
const String _kFurigana = '毎日[まいにち] 図書館[としょかん]に<b>通[かよ]って</b>います';
const String _kPicture = '<img src="data:image/png;base64,iVBORw0KGgo=">';
const String _kAudio = '[sound:a.mp3][sound:b.mp3]';

/// 1×1 透明 PNG。
final List<int> _kPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

String _fid(String name) => srsFushiCardFieldId(kSrsTestProfile, name);

Future<T> _db<T>(WidgetTester tester, Future<T> Function() body) async =>
    (await tester.runAsync(body)) as T;

Future<void> _settle(WidgetTester tester, {int rounds = 12}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Finder _key(String k) => find.byKey(ValueKey<String>(k));

/// 等一次「选图 / 粘贴 / 选音频」真正落地：字段编辑器把字节写进媒体目录（真 IO：
/// exists → create → 写临时文件并 fsync → rename，每一步都要一轮 runAsync + pump 才能
/// 往前走）后才把文件名写回字段、解除 busy、[addButtonKey] 按钮重新可点。磁盘慢时
/// （CI 并发跑 suite、fsync 抖动）固定轮数会在写回前就点保存，字段里只剩旧值；所以按
/// 可观察的完成信号等，超过上限直接失败，不静默往下走。
Future<void> _settleMediaAdd(
  WidgetTester tester,
  String addButtonKey, {
  int maxRounds = 400,
}) => _settleUntil(
  tester,
  () =>
      tester.widget<FushiOutlinedButton>(_key(addButtonKey)).onPressed != null,
  '媒体写入（$addButtonKey 一直处于 busy）',
  maxRounds: maxRounds,
);

/// 逐轮推进真异步，直到 [done] 成立；超过 [maxRounds] 轮直接失败。用于点完会触发
/// 媒体 IO 的按钮之后：完成所需轮数取决于磁盘快慢，不能写死。
Future<void> _settleUntil(
  WidgetTester tester,
  bool Function() done,
  String what, {
  int maxRounds = 400,
}) async {
  for (int i = 0; i < maxRounds; i++) {
    await _settle(tester, rounds: 1);
    if (done()) return;
  }
  fail('$what 在 $maxRounds 轮内没有完成');
}

EditableText _editable(WidgetTester tester, String key) =>
    tester.widget<EditableText>(
      find.descendant(of: _key(key), matching: find.byType(EditableText)),
    );

class _Env {
  _Env(this.store, this.media, this.played);

  final SrsDbStore store;
  final Directory media;
  final List<String> played;
}

Future<_Env> _open(WidgetTester tester) async {
  final (FushiDatabase db, SrsDbStore store) = await _db(
    tester,
    () => openSrsTestStore(),
  );
  addTearDown(() => tester.runAsync(db.close));
  final Directory media = (await _db(
    tester,
    () => Directory.systemTemp.createTemp('srs_editor_media'),
  ));
  addTearDown(() => tester.runAsync(() => media.delete(recursive: true)));
  return _Env(store, media, <String>[]);
}

Future<String> _fushiNote(
  WidgetTester tester,
  SrsDbStore store,
  Map<String, String> fields,
) => _db(
  tester,
  () => store.createNote(
    noteTypeId: store.fushiCardNoteTypeId,
    fieldsById: <String, String>{
      for (final MapEntry<String, String> e in fields.entries)
        _fid(e.key): e.value,
    },
  ),
);

Future<void> _pumpEditor(
  WidgetTester tester,
  _Env env,
  String noteId, {
  bool apple = false,
  Size size = const Size(1100, 2600),
  SrsFieldMediaSource? source,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppModel app = AppModel(testPlatformServices());
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => app),
        srsStoreProvider.overrideWith((Ref ref) async => env.store),
        srsMediaStoreProvider.overrideWith(
          (Ref ref) async => SrsMediaStore(env.media),
        ),
        srsCardFaceBuilderProvider.overrideWithValue(
          (BuildContext context, SrsCardFace face) =>
              SrsPlainCardFace(face: face),
        ),
        srsSoundPlayerProvider.overrideWithValue((String path) async {
          env.played.add(path);
          return true;
        }),
        if (source != null)
          srsFieldMediaSourceProvider.overrideWithValue(source),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            designSystem: apple
                ? FushiDesignSystem.cupertino
                : FushiDesignSystem.material,
            glass: FushiGlassMaterial.off,
            glassDesign: apple,
          ),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: SrsNoteEditorPage(noteId: noteId),
        ),
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(_key('srs_note_save').first);
  await _settle(tester);
}

Future<String> _field(
  WidgetTester tester,
  SrsDbStore store,
  String note,
  String name,
) async => (await _db(tester, () => store.note(note)))!.field(_fid(name));

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('字段类型判据', () {
    test('按内容 / 字段名分到对应编辑器', () {
      expect(
        srsFieldKindOf('MainDefinition', _kGlossary),
        SrsFieldKind.structured,
      );
      expect(srsFieldKindOf('Sentence', _kSentence), SrsFieldKind.rich);
      expect(srsFieldKindOf('Expression', ''), SrsFieldKind.rich);
      expect(
        srsFieldKindOf('SentenceFurigana', _kFurigana),
        SrsFieldKind.furigana,
      );
      expect(srsFieldKindOf('SentenceFurigana', ''), SrsFieldKind.furigana);
      expect(srsFieldKindOf('Back', '毎日[まいにち]'), SrsFieldKind.furigana);
      expect(srsFieldKindOf('Picture', _kPicture), SrsFieldKind.image);
      expect(srsFieldKindOf('Picture', ''), SrsFieldKind.image);
      expect(
        srsFieldKindOf('Front', '<img src="a.png"><br>'),
        SrsFieldKind.image,
      );
      expect(srsFieldKindOf('SentenceAudio', ''), SrsFieldKind.audio);
      expect(srsFieldKindOf('Front', _kAudio), SrsFieldKind.audio);
      expect(
        srsFieldKindOf('Front', 'x [sound:a.mp3]'),
        SrsFieldKind.structured,
      );
      expect(
        srsFieldKindOf('IsSentenceCard', 'x', toggle: true),
        SrsFieldKind.toggle,
      );
      expect(
        srsFieldKindOf('Sentence', '<span class="x">a</span>'),
        SrsFieldKind.structured,
      );
      expect(
        srsFieldKindOf('Sentence', '<span style="color: #ff0000;">a</span>'),
        SrsFieldKind.rich,
      );
    });

    test('[sound:] 解析、替换、追加', () {
      expect(srsSoundNames(_kAudio), <String>['a.mp3', 'b.mp3']);
      expect(srsReplaceSound(_kAudio, 0, null), '[sound:b.mp3]');
      expect(
        srsReplaceSound(_kAudio, 1, 'c.ogg'),
        '[sound:a.mp3][sound:c.ogg]',
      );
      expect(srsAppendSound('', 'd.mp3'), '[sound:d.mp3]');
    });

    test('图片替换只换 src、其余属性原样；删除与追加', () {
      const String html =
          '<img class="pic" src="a.png" width="10"><img src="b.png">';
      expect(
        srsReplaceImage(html, 0, 'c.png'),
        '<img class="pic" src="c.png" width="10"><img src="b.png">',
      );
      expect(
        srsReplaceImage(html, 1, null),
        '<img class="pic" src="a.png" width="10">',
      );
      expect(srsAppendImage('', 'x.png'), '<img src="x.png">');
    });

    test('振假名改读音 / 去注音', () {
      expect(
        srsSetFuriganaReading(_kFurigana, 1, 'としょ'),
        '毎日[まいにち] 図書館[としょ]に<b>通[かよ]って</b>います',
      );
      expect(
        srsSetFuriganaReading(_kFurigana, 0, ''),
        '毎日 図書館[としょかん]に<b>通[かよ]って</b>います',
      );
      expect(
        srsFuriganaPairs(_kFurigana).map((SrsFuriganaPair p) => p.base),
        <String>['毎日', '図書館', '通'],
      );
    });
  });

  group('富文本控制器', () {
    test('没改过原样返回（<strong>、实体都不动）', () {
      final SrsRichTextController c = SrsRichTextController.tryParse(
        _kSentence,
      )!;
      expect(c.text, '毎日図書館に通っています&。');
      expect(c.html, _kSentence);
      c.selection = const TextSelection.collapsed(offset: 2);
      expect(c.html, _kSentence, reason: '只动光标不算改');
      c.dispose();
    });

    test('选区加粗 / 斜体 / 颜色序列化成 Anki 写法', () {
      final SrsRichTextController c = SrsRichTextController.tryParse('毎日図書館')!;
      c.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
      c.toggle(SrsRichAttr.bold);
      expect(c.html, '<b>毎日</b>図書館');
      c.toggle(SrsRichAttr.bold);
      expect(c.html, '毎日図書館');
      c.selection = const TextSelection(baseOffset: 2, extentOffset: 5);
      c.toggle(SrsRichAttr.italic);
      c.setColor(0xFFE53935);
      expect(c.html, '毎日<i><span style="color: #e53935;">図書館</span></i>');
      c.dispose();
    });

    test('折叠光标点加粗后输入的字带加粗；输入继承前一个字的样式', () {
      final SrsRichTextController c = SrsRichTextController.tryParse('ab')!;
      c.selection = const TextSelection.collapsed(offset: 2);
      c.toggle(SrsRichAttr.bold);
      c.value = const TextEditingValue(
        text: 'abc',
        selection: TextSelection.collapsed(offset: 3),
      );
      expect(c.html, 'ab<b>c</b>');
      c.value = const TextEditingValue(
        text: 'abcd',
        selection: TextSelection.collapsed(offset: 4),
      );
      expect(c.html, 'ab<b>cd</b>');
      // 删掉中间的 b：两侧样式各自保留。
      c.value = const TextEditingValue(
        text: 'acd',
        selection: TextSelection.collapsed(offset: 1),
      );
      expect(c.html, 'a<b>cd</b>');
      c.dispose();
    });

    test('换行 ↔ <br>，div 拆行', () {
      final SrsRichTextController c = SrsRichTextController.tryParse(
        '<div>a</div><div>b</div>',
      )!;
      expect(c.text, 'a\nb');
      c.value = const TextEditingValue(
        text: 'a\nbc',
        selection: TextSelection.collapsed(offset: 4),
      );
      expect(c.html, 'a<br>bc');
      c.dispose();
    });
  });

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('[$ds] 原样往返：只改词条，其余字段（含结构化释义 / base64 图）一字不变', (
      WidgetTester tester,
    ) async {
      final _Env env = await _open(tester);
      final Map<String, String> original = <String, String>{
        'Expression': '通う',
        'MainDefinition': _kGlossary,
        'Glossary': _kGlossary,
        'Sentence': _kSentence,
        'ExpressionFurigana': _kFurigana,
        'Picture': _kPicture,
        'ExpressionAudio': '[sound:a.mp3]',
        'IsSentenceCard': 'x',
      };
      final String note = await _fushiNote(tester, env.store, original);
      await _pumpEditor(tester, env, note, apple: apple);

      // 各字段落到对应编辑器。
      expect(_key('srs-field-preview-MainDefinition'), findsOneWidget);
      expect(_key('srs-field-input-MainDefinition'), findsNothing);
      expect(_key('srs-field-input-Sentence'), findsOneWidget);
      expect(_key('srs-furigana-ExpressionFurigana-0'), findsOneWidget);
      expect(_key('srs-image-Picture-0'), findsOneWidget);
      expect(_key('srs-sound-ExpressionAudio-0'), findsOneWidget);
      // Fushi 卡片按卡面区块分组。
      expect(
        _key('srs-note-group-${t.srs_note_block_sentence}'),
        findsOneWidget,
      );

      // 结构化与富文本各切一次源码再切回来，不改内容。
      for (final String name in <String>['MainDefinition', 'Sentence']) {
        await tester.ensureVisible(_key('srs-field-source-$name'));
        await tester.pump();
        await tester.tap(_key('srs-field-source-$name'));
        await _settle(tester, rounds: 4);
        expect(
          _editable(tester, 'srs-field-source-input-$name').controller.text,
          original[name],
        );
        await tester.tap(_key('srs-field-source-$name'));
        await _settle(tester, rounds: 4);
      }

      await tester.enterText(
        find.descendant(
          of: _key('srs-field-input-Expression'),
          matching: find.byType(EditableText),
        ),
        '通う！',
      );
      await tester.pump();
      await _save(tester);

      final SrsNoteView saved = (await _db(
        tester,
        () => env.store.note(note),
      ))!;
      expect(saved.field(_fid('Expression')), '通う！');
      for (final MapEntry<String, String> e in original.entries) {
        if (e.key == 'Expression') continue;
        expect(saved.field(_fid(e.key)), e.value, reason: e.key);
      }
      await _unmount(tester);
    });
  }

  testWidgets(
    '加粗 / 斜体 / 颜色：选中例句里的词点工具条，写回 Anki 写法（触屏与桌面点按都不丢焦点）',
    (WidgetTester tester) async {
      final _Env env = await _open(tester);
      final String note = await _fushiNote(tester, env.store, <String, String>{
        'Expression': '通う',
        'Sentence': '毎日図書館に通っています',
      });
      // 单栏宽度：只测字段本身（两栏分区的滚动条装配不在本测试范围）。
      await _pumpEditor(tester, env, note, size: const Size(700, 2600));

      expect(
        _key('srs-format-bold-Sentence'),
        findsNothing,
        reason: '未聚焦不出工具条',
      );
      await tester.tap(_key('srs-field-input-Sentence'));
      await _settle(tester, rounds: 4);
      final TextEditingController c = _editable(
        tester,
        'srs-field-input-Sentence',
      ).controller;
      c.selection = const TextSelection(baseOffset: 6, extentOffset: 9);
      await tester.pump();
      await tester.tap(_key('srs-format-bold-Sentence'));
      await _settle(tester, rounds: 4);
      expect(
        _editable(tester, 'srs-field-input-Sentence').focusNode.hasFocus,
        isTrue,
      );
      // Ctrl+I 同样生效（快捷键）。
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      // 颜色：展开色板选红色。
      await tester.tap(_key('srs-format-color-Sentence'));
      await _settle(tester, rounds: 4);
      await tester.tap(_key('srs-format-swatch-#e53935'));
      await _settle(tester, rounds: 4);
      await _save(tester);
      expect(
        await _field(tester, env.store, note, 'Sentence'),
        '毎日図書館に<b><i><span style="color: #e53935;">通って</span></i></b>います',
      );
      await _unmount(tester);
    },
    variant: const TargetPlatformVariant(<TargetPlatform>{
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets('图片：选择的图片存进 SRS 媒体库，字段写文件名而不是 base64', (
    WidgetTester tester,
  ) async {
    final _Env env = await _open(tester);
    final String note = await _fushiNote(tester, env.store, <String, String>{
      'Expression': '通う',
      'Picture': _kPicture,
    });
    final Uint8List bytes = Uint8List.fromList(_kPng);
    await _pumpEditor(
      tester,
      env,
      note,
      source: SrsFieldMediaSource(
        pickImage: (_) async => (name: 'Shot.PNG', bytes: bytes),
        pickAudio: (_) async => null,
        pasteImage: () async => (name: 'clipboard.png', bytes: bytes),
      ),
    );
    final String stored = SrsMediaStore.contentName('Shot.PNG', bytes);

    // 替换旧的 base64 图。
    await tester.tap(
      find.descendant(
        of: _key('srs-image-Picture-0'),
        matching: find.byTooltip(t.srs_note_image_replace),
      ),
    );
    await _settleMediaAdd(tester, 'srs-image-paste-Picture');
    // 再粘贴一张（同内容去重，同一个文件名）。
    await tester.tap(_key('srs-image-paste-Picture'));
    await _settleMediaAdd(tester, 'srs-image-paste-Picture');
    expect(_key('srs-image-Picture-1'), findsOneWidget);
    await _save(tester);

    final String value = await _field(tester, env.store, note, 'Picture');
    expect(value, '<img src="$stored"><img src="$stored">');
    expect(value, isNot(contains('base64')));
    expect(stored, endsWith('.png'));
    expect(
      await _db(tester, () => File('${env.media.path}/$stored').exists()),
      isTrue,
    );
    await _unmount(tester);
  });

  testWidgets('音频：[sound:] 列成播放行，可播放 / 删除 / 选择文件追加', (
    WidgetTester tester,
  ) async {
    final _Env env = await _open(tester);
    await _db(
      tester,
      () => File('${env.media.path}/b.mp3').writeAsBytes(<int>[1, 2, 3]),
    );
    final String note = await _fushiNote(tester, env.store, <String, String>{
      'Expression': '通う',
      'ExpressionAudio': _kAudio,
    });
    final Uint8List voice = Uint8List.fromList(<int>[9, 9, 9]);
    await _pumpEditor(
      tester,
      env,
      note,
      source: SrsFieldMediaSource(
        pickImage: (_) async => null,
        pickAudio: (_) async => (name: 'voice.MP3', bytes: voice),
        pasteImage: () async => null,
      ),
    );
    expect(find.text('a.mp3'), findsOneWidget);
    expect(find.text('b.mp3'), findsOneWidget);

    await tester.tap(_key('srs-sound-play-ExpressionAudio-1'));
    // 播放前要先查文件在不在（真 IO），等播放器真被调用再断言。
    await _settleUntil(tester, () => env.played.isNotEmpty, '播放 b.mp3');
    expect(env.played.single, endsWith('b.mp3'));

    await tester.tap(
      find.descendant(
        of: _key('srs-sound-ExpressionAudio-0'),
        matching: find.byTooltip(t.srs_note_audio_remove),
      ),
    );
    await _settle(tester, rounds: 4);
    expect(find.text('a.mp3'), findsNothing);
    await tester.tap(_key('srs-sound-pick-ExpressionAudio'));
    await _settleMediaAdd(tester, 'srs-sound-pick-ExpressionAudio');
    await _save(tester);
    final String voiceName = SrsMediaStore.contentName('voice.MP3', voice);
    expect(
      await _field(tester, env.store, note, 'ExpressionAudio'),
      '[sound:b.mp3][sound:$voiceName]',
    );
    await _unmount(tester);
  });

  testWidgets('HTML 源码：Ctrl+Shift+X 切到源码、改完切回可视化，按源码保存', (
    WidgetTester tester,
  ) async {
    final _Env env = await _open(tester);
    final String note = await _fushiNote(tester, env.store, <String, String>{
      'Expression': '通う',
      'Sentence': _kSentence,
    });
    await _pumpEditor(tester, env, note);

    await tester.tap(_key('srs-field-input-Sentence'));
    await _settle(tester, rounds: 4);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await _settle(tester, rounds: 4);
    expect(_key('srs-field-input-Sentence'), findsNothing);
    final EditableText source = _editable(
      tester,
      'srs-field-source-input-Sentence',
    );
    expect(source.controller.text, _kSentence);
    expect(source.focusNode.hasFocus, isTrue, reason: '切换后焦点落在源码框');

    await tester.enterText(
      find.descendant(
        of: _key('srs-field-source-input-Sentence'),
        matching: find.byType(EditableText),
      ),
      '<i>毎日</i>図書館',
    );
    await tester.pump();
    await tester.tap(_key('srs-field-source-Sentence'));
    await _settle(tester, rounds: 4);
    expect(
      _editable(tester, 'srs-field-input-Sentence').controller.text,
      '毎日図書館',
    );
    await _save(tester);
    expect(await _field(tester, env.store, note, 'Sentence'), '<i>毎日</i>図書館');
    await _unmount(tester);
  });

  testWidgets('注音：点词弹出读音框，改完写回 Anki 写法', (WidgetTester tester) async {
    final _Env env = await _open(tester);
    final String note = await _fushiNote(tester, env.store, <String, String>{
      'Expression': '通う',
      'ExpressionFurigana': _kFurigana,
    });
    await _pumpEditor(tester, env, note);
    expect(find.text('としょかん'), findsOneWidget, reason: '读音画在基字上方');

    await tester.tap(_key('srs-furigana-ExpressionFurigana-1'));
    await _settle(tester, rounds: 6);
    await tester.enterText(find.byType(EditableText).last, 'としょ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester, rounds: 6);
    expect(find.text('としょ'), findsOneWidget);
    await _save(tester);
    expect(
      await _field(tester, env.store, note, 'ExpressionFurigana'),
      '毎日[まいにち] 図書館[としょ]に<b>通[かよ]って</b>います',
    );
    await _unmount(tester);
  });

  testWidgets('卡型开关字段：开关切换写 x / 清空', (WidgetTester tester) async {
    final _Env env = await _open(tester);
    final String note = await _fushiNote(tester, env.store, <String, String>{
      'Expression': '通う',
    });
    await _pumpEditor(tester, env, note);
    await tester.tap(_key('srs-note-more-fields'));
    await _settle(tester, rounds: 6);
    final Finder toggle = _key('srs-field-toggle-IsSentenceCard');
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await _settle(tester, rounds: 4);
    await _save(tester);
    expect(await _field(tester, env.store, note, 'IsSentenceCard'), 'x');
    await _unmount(tester);
  });
}
