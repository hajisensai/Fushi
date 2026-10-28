// 内置「Fushi 卡片」模板：没有宿主（Anki 默认值）时能渲染、宿主注入的变量都有默认值、
// 套进真实卡面外壳后的整页 HTML。
//
// 设了环境变量 FUSHI_SRS_PREVIEW_OUT（目录）时，额外把「真外壳 + 真模板 + 外观注入」的整页
// HTML 写到那里（窄 / 宽 × 浅 / 深 × 统一词典样式开 / 关），供无头浏览器截图。
// FUSHI_SRS_PREVIEW_SAMPLES 指向一份 [{fields:{…}}] JSON 时，额外用其中的真实导出释义出页。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_card_tokens.dart';
import 'package:fushi/src/srs/srs_card_sample.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:material_ui/material_ui.dart';

AnkiRenderedCard _render(Map<String, String> fields) => renderAnkiCard(
  questionTemplate: FushiCardNoteType.template.front,
  answerTemplate: FushiCardNoteType.template.back,
  noteFields: fields,
  cardOrd: 0,
  isCloze: false,
);

void main() {
  test('renders with Anki defaults (no host): no unresolved mustaches', () {
    final AnkiRenderedCard card = _render(srsSampleCardFields());
    expect(card.isEmpty, isFalse);
    for (final String face in <String>[card.question, card.answer]) {
      expect(face, isNot(contains('{{')));
      expect(face, isNot(contains('}}')));
    }
    expect(card.answer, contains('fc-back'));
    expect(card.answer, contains('fc-sentence'));
    expect(card.answer, contains('几乎每天都去图书馆。'));
  });

  test('an empty Lapis-shaped note (only Expression) still renders', () {
    final AnkiRenderedCard card = _render(<String, String>{
      for (final String f in FushiCardNoteType.fields) f: '',
      'Expression': '箔',
    });
    expect(card.isEmpty, isFalse);
    expect(card.question, contains('箔'));
    expect(card.answer, isNot(contains('fc-translation')));
    expect(card.answer, isNot(contains('fc-sentence-block')));
  });

  test('every host variable the template reads has a default value', () {
    final String all = <String>[
      FushiCardNoteType.template.front,
      FushiCardNoteType.template.back,
      FushiCardNoteType.template.css,
    ].join('\n');
    final Iterable<RegExpMatch> bare = RegExp(
      r'var\(\s*--fushi-srs-[a-z0-9-]+\s*\)',
    ).allMatches(all);
    expect(bare.map((RegExpMatch m) => m.group(0)), isEmpty);
    // 宿主注入的每个变量模板都真的在读（防注入表与模板令牌表漂移）。
    final String injected = srsCardAppearanceCss(
      appearance: const SrsCardAppearance(),
      fonts: const <Map<String, dynamic>>[
        <String, dynamic>{'name': 'A'},
      ],
      tokens: SrsCardTokens.fromTheme(ThemeData()),
      appScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
      dark: false,
      labels: const SrsCardLabels(
        allDefinitions: 'a',
        frequency: 'f',
        source: 's',
      ),
      fontUrl: (String p) => p,
    );
    final Set<String> names = RegExp(
      r'(--fushi-srs-[a-z0-9-]+):',
    ).allMatches(injected).map((RegExpMatch m) => m.group(1)!).toSet();
    expect(names, isNotEmpty);
    for (final String name in names) {
      expect(
        FushiCardNoteType.template.css,
        contains('var($name,'),
        reason: '$name is injected but the template never reads it',
      );
    }
  });

  test('Fushi card no longer shows SentenceFurigana (owner 2026-10-28)', () {
    // 字段仍留在笔记类型里（与 Lapis 同名同序），卡面与外观不再读它。
    for (final String part in <String>[
      FushiCardNoteType.template.front,
      FushiCardNoteType.template.back,
      FushiCardNoteType.template.css,
    ]) {
      expect(part, isNot(contains('SentenceFurigana')));
      expect(part, isNot(contains('fushi-srs-sentence-furigana')));
    }
    for (final FushiCardBlock b in FushiCardBlock.values) {
      expect(b.fields, isNot(contains('SentenceFurigana')));
    }
    expect(
      const SrsCardAppearance().toJson().containsKey('sentenceFurigana'),
      isFalse,
    );
  });

  test('every host class the appearance can emit is styled by the template', () {
    final String classes = srsCardAppearanceClasses(
      const SrsCardAppearance(
        frontReading: true,
        frontFrequency: true,
        glossaryExpanded: true,
        showPicture: false,
        showTranslation: false,
        showFrequency: false,
        showSource: false,
        density: SrsCardDensity.compact,
      ),
    );
    final String all =
        '${FushiCardNoteType.template.css}\n${FushiCardNoteType.template.back}';
    for (final String c in classes.split(' ')) {
      expect(all, contains(c), reason: 'host class $c is not used');
    }
    expect(
      FushiCardNoteType.template.css,
      contains('fushi-srs-density-comfortable'),
    );
    expect(FushiCardNoteType.template.css, contains('fushi-srs-dict-unified'));
    // 外观页预览强制版式用的宿主类名由背面脚本识别（覆盖自动断点）。
    for (final SrsCardLayout l in <SrsCardLayout>[
      SrsCardLayout.narrow,
      SrsCardLayout.wide,
    ]) {
      expect(FushiCardNoteType.template.back, contains(l.hostClass));
    }
    expect(FushiCardNoteType.template.css, contains('.fc-back.fc-layout-wide'));
  });

  test('style registry: consecutive cards send each style body once', () async {
    // 用 FUSHI_SRS_PREVIEW_SAMPLES 的真实导出释义量换卡调用串字节数（没有就用样例）。
    final List<Map<String, String>> notes = <Map<String, String>>[
      srsSampleCardFields(),
    ];
    final String? samplesPath =
        Platform.environment['FUSHI_SRS_PREVIEW_SAMPLES'];
    if (samplesPath != null && samplesPath.isNotEmpty) {
      for (final Object? raw
          in jsonDecode(File(samplesPath).readAsStringSync())
              as List<Object?>) {
        notes.add(<String, String>{
          for (final String k in FushiCardNoteType.fields) k: '',
          ...((raw! as Map)['fields'] as Map).cast<String, String>(),
        });
      }
    }
    final List<String> sent = <String>[];
    final SrsCardFaceSync sync = SrsCardFaceSync(
      evaluate: (String s) async {
        sent.add(s);
        return true;
      },
      reloadShell: () {},
    )..shellLoaded();
    int before = 0;
    for (int i = 0; i < notes.length; i++) {
      final AnkiRenderedCard card = _render(notes[i]);
      for (final bool answer in <bool>[false, true]) {
        final SrsCardFaceDocument doc = SrsCardFaceDocument.of(
          SrsCardFace(
            cardId: 'n$i',
            showingAnswer: answer,
            bodyHtml: answer ? card.answer : card.question,
            css: FushiCardNoteType.template.css,
            languageCode: 'ja',
            onBridgeKey: (_) {},
          ),
          dark: false,
          background: const Color(0xFFFFFFFF),
          foreground: const Color(0xFF000000),
          accent: const Color(0xFF386A58),
          onAccent: const Color(0xFFFFFFFF),
          mediaUrlPrefix: 'https://srs.local/media/',
          themedScrollbar: true,
        );
        // 改前：每次换卡都整段带笔记类型 CSS 与原样正文（含 <style>）。
        before +=
            FushiCardNoteType.template.css.length +
            (answer ? card.answer : card.question).length;
        sync.update(doc);
        await Future<void>.delayed(Duration.zero);
      }
    }
    final String all = sent.join();
    expect(
      RegExp(RegExp.escape('fushi-srs-pitch-kifuku, #7e53c4')).allMatches(all),
      hasLength(1),
      reason: 'template CSS body must be sent once',
    );
    final int after =
        sent.skip(1).fold<int>(0, (int a, String s) => a + s.length) +
        sent.first.length;
    // ignore: avoid_print
    print(
      'srs card calls: ${notes.length} notes x2 faces, '
      'before=${before ~/ 1024} KiB, after=${after ~/ 1024} KiB',
    );
    expect(after, lessThan(before));
  });

  test('dump full-shell preview pages (only with FUSHI_SRS_PREVIEW_OUT)', () {
    final String? out = Platform.environment['FUSHI_SRS_PREVIEW_OUT'];
    if (out == null || out.isEmpty) return;
    final Directory dir = Directory(out)..createSync(recursive: true);
    final List<(String, Map<String, String>)> samples =
        <(String, Map<String, String>)>[('sample', srsSampleCardFields())];
    final String? samplesPath =
        Platform.environment['FUSHI_SRS_PREVIEW_SAMPLES'];
    if (samplesPath != null && samplesPath.isNotEmpty) {
      final List<Object?> raw =
          jsonDecode(File(samplesPath).readAsStringSync()) as List<Object?>;
      for (int i = 0; i < raw.length; i++) {
        final Map<String, String> f = <String, String>{
          for (final String k in FushiCardNoteType.fields) k: '',
          ...((raw[i]! as Map)['fields'] as Map).cast<String, String>(),
        };
        // 真实样本的图片 / 音频是媒体库里的文件名，预览页没有媒体库：换成样例图。
        f['Picture'] = srsSampleCardFields()['Picture']!;
        samples.add(('real$i', f));
      }
    }
    const SrsCardLabels zh = SrsCardLabels(
      allDefinitions: '全部释义',
      frequency: '词频',
      source: '来源',
      showMore: '展开全文',
    );
    // FUSHI_SRS_PREVIEW_APPEARANCE：外观 JSON（量「关掉手机精简」等对照用）。
    final SrsCardAppearance base = SrsCardAppearance.decode(
      Platform.environment['FUSHI_SRS_PREVIEW_APPEARANCE'] ?? '',
    );
    for (final (String name, Map<String, String> fields) in samples) {
      final AnkiRenderedCard card = _render(fields);
      for (final bool dark in <bool>[false, true]) {
        final ColorScheme scheme = ColorScheme.fromSeed(
          seedColor: const Color(0xFF386A58),
          brightness: dark ? Brightness.dark : Brightness.light,
        );
        for (final bool unified in <bool>[true, false]) {
          for (final bool answer in <bool>[false, true]) {
            if (!answer && (!unified || name != 'sample')) continue;
            final SrsCardAppearance appearance = base.copyWith(
              dictUnified: unified,
            );
            final SrsCardFaceDocument doc = SrsCardFaceDocument.of(
              SrsCardFace(
                cardId: name,
                showingAnswer: answer,
                bodyHtml: answer ? card.answer : card.question,
                css: FushiCardNoteType.template.css,
                languageCode: 'ja',
                onBridgeKey: (_) {},
              ),
              dark: dark,
              background: scheme.surface,
              foreground: scheme.onSurface,
              accent: scheme.primary,
              onAccent: scheme.onPrimary,
              mediaUrlPrefix: 'https://srs.local/media/',
              themedScrollbar: true,
              appearanceCss: srsCardAppearanceCss(
                appearance: appearance,
                tokens: SrsCardTokens.fromTheme(ThemeData()),
                appScheme: scheme,
                dark: dark,
                labels: zh,
                fontUrl: (String p) => p,
              ),
              appearanceClasses: srsCardAppearanceClasses(appearance),
            );
            // 内联进 <script> 时卡面里的 `</script>` 会提前结束脚本：JS 字符串里写成 `<\/`。
            final String call = doc.fullCardScript.replaceAll('</', r'<\/');
            final String html = doc.shellHtml.replaceFirst(
              '</body>',
              '<script>$call</script></body>',
            );
            final String file =
                '$name-${answer ? 'back' : 'front'}-${dark ? 'dark' : 'light'}'
                '-${unified ? 'unified' : 'original'}.html';
            File('${dir.path}/$file').writeAsStringSync(html);
          }
        }
      }
    }
    // 外观页预览的强制版式：桌面版式在窄预览区里靠页面内 zoom（forced-wide-zoom，按 600px
    // 宽截图）、手机版式在宽预览区里强制单栏（forced-narrow）。
    final AnkiRenderedCard sample = _render(srsSampleCardFields());
    final ColorScheme light = ColorScheme.fromSeed(
      seedColor: const Color(0xFF386A58),
    );
    for (final (String name, SrsCardLayout layout, double? zoom)
        in <(String, SrsCardLayout, double?)>[
          ('forced-wide-zoom', SrsCardLayout.wide, 600 / 1100),
          ('forced-narrow', SrsCardLayout.narrow, null),
        ]) {
      const SrsCardAppearance appearance = SrsCardAppearance();
      final SrsCardFaceDocument doc = SrsCardFaceDocument.of(
        SrsCardFace(
          cardId: name,
          showingAnswer: true,
          bodyHtml: sample.answer,
          css: FushiCardNoteType.template.css,
          languageCode: 'ja',
          onBridgeKey: (_) {},
          layout: layout,
          pageZoom: zoom,
        ),
        dark: false,
        background: light.surface,
        foreground: light.onSurface,
        accent: light.primary,
        onAccent: light.onPrimary,
        mediaUrlPrefix: 'https://srs.local/media/',
        themedScrollbar: true,
        appearanceCss: srsCardAppearanceCss(
          appearance: appearance,
          tokens: SrsCardTokens.fromTheme(ThemeData()),
          appScheme: light,
          dark: false,
          labels: zh,
          fontUrl: (String p) => p,
        ),
        appearanceClasses: srsCardAppearanceClasses(appearance),
      );
      final String call = doc.fullCardScript.replaceAll('</', r'<\/');
      File('${dir.path}/sample-$name.html').writeAsStringSync(
        doc.shellHtml.replaceFirst('</body>', '<script>$call</script></body>'),
      );
    }
  });
}
