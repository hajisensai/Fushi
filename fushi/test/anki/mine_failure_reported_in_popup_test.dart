import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/ankimobile_repository.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../pages/reader_fushi_page_source_corpus.dart';

// BUG-3652（用户 2026-10-21 iOS 反馈 + 截图）：
//   ① 选了非 Lapis 笔记类型后字段映射是空表，每次制卡都被空卡门拒掉，而这条失败不带
//      错误码，toast 里是后端英文原文「All fields are empty — refusing to create a
//      blank card…」。
//   ② 弹窗发起的同一次失败报两遍：宿主一条 Flutter toast + 弹窗一个不带原因的
//      「导出卡片失败。」；iOS 上那条 toast 还落在底部停靠的弹窗上，被弹窗边缘裁掉。
// 修法：空卡门带 [AnkiErrorCode.allFieldsEmpty] → 本地化成能照着做的一句话；弹窗
// 发起的失败只在弹窗按钮旁说一次（[MinePopupResult.message]），宿主不再另弹 toast。
//
// BUG-3723 之后空映射在载入时就补成按字段名推出的默认映射，① 的「空表」本身不再出现；
// 空卡门仍要守住「映射覆盖到了笔记类型、但渲染出来全空」（这里 Front 映射到一个本次
// 词条没有的读音）。

const AnkiSettings _nonLapisWithoutMappings = AnkiSettings(
  selectedDeckId: 0,
  selectedDeckName: 'Korean',
  selectedNoteTypeId: 7,
  selectedNoteTypeName: 'Basic',
  availableDecks: <AnkiDeck>[AnkiDeck(id: 0, name: 'Korean')],
  availableNoteTypes: <AnkiNoteType>[
    AnkiNoteType(id: 7, name: 'Basic', fields: <String>['Front', 'Back']),
  ],
  fieldMappings: <String, String>{'Front': '{reading}'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  LocaleSettings.setLocaleRaw('zh-CN');

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('空映射 → allFieldsEmpty → 本地化文案', () {
    test(
      'AnkiMobile：非 Lapis 笔记类型 + 映射渲染全空，失败带 allFieldsEmpty 且不打开 Anki',
      () async {
        final List<Uri> launched = <Uri>[];
        final AnkiMobileRepository repo = AnkiMobileRepository(
          openUrl: (Uri uri) async {
            launched.add(uri);
            return true;
          },
          readInfoForAddingJson: () async =>
              const AnkiMobilePasteboardRead.empty(),
          mediaServerLifetime: Duration.zero,
        );
        await repo.saveSettings(_nonLapisWithoutMappings);

        final MineOutcome outcome = await repo.mineEntry(
          rawPayloadJson: jsonEncode(<String, String>{'expression': '봐'}),
          context: const AnkiMiningContext(sentence: '누가 두고 갔나 봐.'),
        );

        expect(outcome.result, MineResult.error);
        expect(outcome.errorCode, AnkiErrorCode.allFieldsEmpty);
        expect(launched, isEmpty, reason: '空卡不该把用户送去 AnkiMobile');
      },
    );

    test('logMineFailure 给的是中文可操作文案，不是后端英文原文', () {
      final String msg = logMineFailure(
        MineOutcome.failure(
          'All fields are empty — refusing to create a blank card. '
          'Check your note type field mappings.',
          errorCode: AnkiErrorCode.allFieldsEmpty,
        ),
      );
      expect(msg, t.anki_error_all_fields_empty);
      expect(msg, contains('字段映射'));
      expect(msg, isNot(contains('All fields are empty')));
    });
  });

  group('弹窗发起的制卡失败只在弹窗里说一次', () {
    test('MinePopupResult.failed 把原因序列化给 popup.js', () {
      final Map<String, Object?> json = MinePopupResult.failed(
        const MineOutcome(MineResult.error),
        message: '原因',
      ).toJson();
      expect(json['message'], '原因');
      expect(json['ankiConnect'], isFalse);

      final Map<String, Object?> duplicate = MinePopupResult.failed(
        const MineOutcome(MineResult.duplicate),
        message: '已存在',
      ).toJson();
      expect(duplicate['duplicate'], isTrue);
      expect(duplicate['message'], '已存在');

      // 不传原因 = 弹窗退回通用文案，不带空串字段。
      expect(
        MinePopupResult.failed(
          const MineOutcome(MineResult.error),
        ).toJson().containsKey('message'),
        isFalse,
      );
      expect(
        MinePopupResult.failed(
          const MineOutcome(MineResult.error),
          message: '',
        ).toJson().containsKey('message'),
        isFalse,
      );
    });

    // 这些表面的制卡入口只由查词弹窗调用，失败结果回到弹窗、由 popup.js 在按钮旁显示。
    // 视频页（OSD）与串流页（自己的状态行）另有展示，不在此列。
    final Map<String, String Function()> surfaces = <String, String Function()>{
      'dictionary_page_mixin': () => File(
        'lib/src/pages/implementations/dictionary_page_mixin.dart',
      ).readAsStringSync(),
      'reader_fushi': readReaderPageSource,
      'manga_fushi_page': () => File(
        'lib/src/media/manga/reader/manga_fushi_page.dart',
      ).readAsStringSync(),
      'reader_pdf_page': () => File(
        'lib/src/pages/implementations/reader_pdf_page.dart',
      ).readAsStringSync(),
      'texthooker_page': () => File(
        'lib/src/pages/implementations/texthooker_page.dart',
      ).readAsStringSync(),
      'overlay_bridge_handlers': () => File(
        'lib/src/lookup/overlay_bridge_handlers.dart',
      ).readAsStringSync(),
    };

    for (final MapEntry<String, String Function()> surface
        in surfaces.entries) {
      test('${surface.key}：失败把原因交给弹窗，结果 toast 只在被收下时弹', () {
        final String src = surface.value();
        expect(
          src.contains('MinePopupResult.failed(outcome)'),
          isFalse,
          reason: '失败回包必须带 message: described.message，否则弹窗只能说「导出卡片失败」',
        );
        expect(
          src.contains(
            'MinePopupResult.failed(outcome, message: described.message)',
          ),
          isTrue,
        );
        // 每一处把 described.message 弹成 toast 的地方，都必须在成功分支里。
        final RegExp toast = RegExp(
          r'FushiToast\.show(?:Mine)?\(\s*msg:\s*described\.message',
        );
        for (final RegExpMatch m in toast.allMatches(src)) {
          final int from = m.start - 160 < 0 ? 0 : m.start - 160;
          expect(
            src.substring(from, m.start).contains('if (described.success) {'),
            isTrue,
            reason:
                '${surface.key} 在成功分支之外弹了制卡结果 toast：'
                '${src.substring(m.start, m.end)}',
          );
        }
      });
    }

    test('「已制卡动作」对话框失败时原样交回带原因的结果', () {
      for (final String path in <String>[
        'lib/src/pages/base_source_page.dart',
        'lib/src/pages/implementations/dictionary_page_mixin.dart',
      ]) {
        final String src = File(path).readAsStringSync();
        expect(
          src.contains('if (!res.accepted) failed = res;'),
          isTrue,
          reason: '$path 新增 / 覆写失败时要记下原结果',
        );
        expect(
          src.contains('if (!r.ankiConnect && failed != null) return failed!;'),
          isTrue,
          reason: '$path 失败时必须交回带 message 的原结果，不能重新拼一个空的',
        );
      }
    });
  });
}
