import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi/src/anki/anki_mined_card_action_sheet.dart';
import 'package:fushi/utils.dart';
import '../helpers/glass_unwrap.dart';

/// TODO-1007/1008：点 ✓ 操作选择 + note viewer 的 widget 行为守卫。
///
/// 决策②：命中多张时列出全部供选择（不默默取最近一张）。
/// 决策③：每次点 ✓ 都让用户选——至少 [覆写] / [新增重复卡] / [查看·在 Anki 中打开]。
/// 决策⑤：note viewer 只读展示字段 + 覆写 + 在 Anki 中打开。

/// 受控假 repo：findMatchingNotes / noteFields / openNoteInAnki 走内存数据。
class _FakeRepo extends BaseAnkiRepository {
  _FakeRepo(this.matches, {this.fields = const {}});

  final List<MinedNoteRef> matches;
  final Map<String, String> fields;
  int openedNoteId = -1;

  @override
  Future<List<MinedNoteRef>> findMatchingNotes(
    String expression,
    String reading,
  ) async => matches;

  @override
  Future<Map<String, String>?> noteFields(int noteId) async => fields;

  // 实现了按 id 打开，按 BUG-3790 的契约同时声明可打开（否则按钮不出）。
  @override
  bool get canOpenMinedNote => true;

  @override
  Future<bool> openNoteInAnki(int noteId) async {
    openedNoteId = noteId;
    return true;
  }

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('unused');
  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async => const MineOutcome.success();
  @override
  Future<bool> isDuplicate(String expression, String reading) async => true;
  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;
  @override
  Future<bool> createDeck(String name) async => false;
}

/// 回读不了 Anki 的后端（AnkiMobile）：反查恒空，但那**不代表**卡不在库里。
class _UnverifiableRepo extends _FakeRepo {
  _UnverifiableRepo() : super(const []);

  final List<String> forgotten = <String>[];

  @override
  bool get canVerifyExistingCards => false;

  @override
  Future<bool> forgetMinedCard(String expression) async {
    forgotten.add(expression);
    return true;
  }
}

/// 删得了卡的后端（AnkiConnect / AnkiDroid / Fushi 复习）：反馈 JNyykxvuY9。
class _DeletableRepo extends _FakeRepo {
  _DeletableRepo(super.matches, {this.fail = false});

  final bool fail;
  final List<int> deleted = <int>[];

  @override
  bool get canDeleteMinedNotes => true;

  @override
  Future<bool> deleteMinedNote(int noteId) async {
    if (fail) throw StateError('AnkiConnect unreachable');
    deleted.add(noteId);
    return true;
  }
}

Widget _host(Future<void> Function(BuildContext) onTapBody) {
  return TranslationProvider(
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => onTapBody(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  // 回读不了 Anki 的后端（AnkiMobile）上点 ✓：反查恒空，既不能当「卡还在」（用户
  // 可能早就在 Anki 里删了，那 ✓ 是谎），也不能当「卡没了」直接重制（卡还在时就
  // 默默多出第二张）。用户报「卡片删掉也不会检测是否还存在」——iOS 没有任何自动
  // 核对的通道，只能把这个判断交还给唯一知道答案的人。
  testWidgets('回读不了 Anki 的后端：反查为空时让用户裁决，而不是默默重制', (tester) async {
    final repo = _UnverifiableRepo();
    var mineNewCalls = 0;
    AnkiCardMutationResult? result;

    await tester.pumpWidget(
      _host((context) async {
        result = await runAnkiMinedCardAction(
          context: context,
          repo: repo,
          expression: '見物',
          reading: 'けんぶつ',
          mineNew: () async {
            mineNewCalls++;
            return (ankiConnect: true, noteId: 111);
          },
          overwrite: (noteId) async => (ankiConnect: true, noteId: noteId),
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(mineNewCalls, 0, reason: '反查为空不得直接重制，先问用户');
    expect(find.text(t.anki_mined_unverified_title), findsOneWidget);
    expect(find.text(t.anki_mined_action_add_duplicate), findsOneWidget);
    expect(find.text(t.anki_mined_action_forget), findsOneWidget);

    // 「我已在 Anki 里删了」→ 划掉本地记录，✓ 变回 +。
    await tester.tap(
      find.byKey(const ValueKey('anki-mined-unverified-forget')),
    );
    await tester.pumpAndSettle();
    expect(repo.forgotten, <String>['見物']);
    expect(mineNewCalls, 0, reason: '纠正记录不该顺手再制一张卡');
    expect(result, isNotNull);
    expect(result!.ankiConnect, isFalse);
    expect(result!.noteId, isNull);
  });

  testWidgets('回读不了 Anki 的后端：选「再加一张」才走制卡链路', (tester) async {
    final repo = _UnverifiableRepo();
    var mineNewCalls = 0;
    AnkiCardMutationResult? result;

    await tester.pumpWidget(
      _host((context) async {
        result = await runAnkiMinedCardAction(
          context: context,
          repo: repo,
          expression: '見物',
          reading: 'けんぶつ',
          mineNew: () async {
            mineNewCalls++;
            return (ankiConnect: true, noteId: 222);
          },
          overwrite: (noteId) async => (ankiConnect: true, noteId: noteId),
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('anki-mined-unverified-add')));
    await tester.pumpAndSettle();

    expect(mineNewCalls, 1);
    expect(repo.forgotten, isEmpty);
    expect(result!.noteId, 222);
  });

  testWidgets('能回读 Anki 的后端：反查为空仍按旧路直接重制（不多一次弹窗）', (tester) async {
    // AnkiConnect / AnkiDroid 每次都真问 Anki，反查不到就是真的没有——这条路
    // 一步都不许多（Never break userspace）。
    final repo = _FakeRepo(const []);
    var mineNewCalls = 0;
    AnkiCardMutationResult? result;

    await tester.pumpWidget(
      _host((context) async {
        result = await runAnkiMinedCardAction(
          context: context,
          repo: repo,
          expression: '見物',
          reading: 'けんぶつ',
          mineNew: () async {
            mineNewCalls++;
            return (ankiConnect: true, noteId: 333);
          },
          overwrite: (noteId) async => (ankiConnect: true, noteId: noteId),
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text(t.anki_mined_unverified_title), findsNothing);
    expect(mineNewCalls, 1);
    expect(result!.noteId, 333);
  });

  testWidgets('lists every matching card (decision 2) + three options', (
    tester,
  ) async {
    final repo = _FakeRepo(const [
      MinedNoteRef(noteId: 300, preview: '日本語 A'),
      MinedNoteRef(noteId: 200, preview: '日本語 B'),
    ]);
    AnkiCardMutationResult? result;

    await tester.pumpWidget(
      _host((context) async {
        result = await runAnkiMinedCardAction(
          context: context,
          repo: repo,
          expression: '日本語',
          reading: 'にほんご',
          mineNew: () async => (ankiConnect: true, noteId: 999),
          overwrite: (noteId) async => (ankiConnect: true, noteId: noteId),
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Both matching cards are listed (multi-match selection).
    expect(find.text('日本語 A'), findsOneWidget);
    expect(find.text('日本語 B'), findsOneWidget);
    // The "add as a new card" option is always present (decision 3).
    expect(find.text(t.anki_mined_action_add_duplicate), findsOneWidget);
    // Per-card overwrite + view affordances exist (two cards -> two each).
    expect(find.byIcon(FushiIcons.edit), findsNWidgets(2));
    expect(find.byIcon(FushiIcons.openInNew), findsNWidgets(2));

    // Choosing "add as a new card" runs mineNew.
    await tester.tap(find.text(t.anki_mined_action_add_duplicate));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.noteId, 999);
    expect(result!.ankiConnect, isTrue);
  });

  testWidgets('overwriting a specific card targets that note id', (
    tester,
  ) async {
    final repo = _FakeRepo(const [
      MinedNoteRef(noteId: 300, preview: 'A'),
      MinedNoteRef(noteId: 200, preview: 'B'),
    ]);
    AnkiCardMutationResult? result;
    await tester.pumpWidget(
      _host((context) async {
        result = await runAnkiMinedCardAction(
          context: context,
          repo: repo,
          expression: 'x',
          reading: '',
          mineNew: () async => (ankiConnect: true, noteId: 999),
          overwrite: (noteId) async => (ankiConnect: true, noteId: noteId),
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Overwrite the SECOND card (note 200) via its edit icon.
    await tester.tap(find.byIcon(FushiIcons.edit).last);
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(
      result!.noteId,
      200,
      reason: 'overwrite targets the user-chosen card, not the newest',
    );
  });

  testWidgets('no matches falls back to mineNew (deleted since detection)', (
    tester,
  ) async {
    final repo = _FakeRepo(const []);
    AnkiCardMutationResult? result;
    await tester.pumpWidget(
      _host((context) async {
        result = await runAnkiMinedCardAction(
          context: context,
          repo: repo,
          expression: 'gone',
          reading: '',
          mineNew: () async => (ankiConnect: true, noteId: 42),
          overwrite: (noteId) async => (ankiConnect: false, noteId: null),
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // No sheet shown; mined fresh directly.
    expect(result, isNotNull);
    expect(result!.noteId, 42);
  });

  testWidgets('note viewer shows fields read-only + open in Anki (decision 5)', (
    tester,
  ) async {
    final repo = _FakeRepo(
      const [MinedNoteRef(noteId: 300, preview: 'A')],
      fields: const {'Expression': '日本語', 'Meaning': 'language'},
    );
    await tester.pumpWidget(
      _host((context) async {
        await runAnkiMinedCardAction(
          context: context,
          repo: repo,
          expression: '日本語',
          reading: '',
          mineNew: () async => (ankiConnect: true, noteId: 999),
          overwrite: (noteId) async => (ankiConnect: true, noteId: noteId),
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Open the viewer via the view icon.
    await tester.tap(find.byIcon(FushiIcons.openInNew));
    await tester.pumpAndSettle();
    // BUG-2503: the viewer replaces candidate content in the same dialog route.
    expect(find.byType(AlertDialog, skipOffstage: false), findsOneWidget);
    expect(
      find.text(t.anki_mined_card_title, skipOffstage: false),
      findsNothing,
    );
    // Field names + values are shown read-only.
    expect(find.text('Expression'), findsOneWidget);
    expect(find.text('日本語'), findsWidgets);
    expect(find.text('Meaning'), findsOneWidget);
    expect(find.text('language'), findsOneWidget);
    // "Open in Anki" triggers repo.openNoteInAnki for this note.
    await tester.tap(find.text(t.anki_note_viewer_open_in_anki));
    await tester.pumpAndSettle();
    expect(repo.openedNoteId, 300);
    // Closing the viewer must finish this action, not reveal a second modal.
    await tester.tap(find.text(t.dialog_close));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
  });

  testWidgets(
    'source field changes expose complete values and return only explicitly selected fields',
    (WidgetTester tester) async {
      final String original =
          '${List<String>.filled(1000, 'original ').join()}original end';
      final String candidate =
          '${List<String>.filled(1000, 'candidate ').join()}candidate end';
      Map<String, String>? selected;
      await tester.pumpWidget(
        _host((BuildContext context) async {
          selected = await showAnkiSourceNoteChanges(
            context: context,
            original: <String, String>{
              'Sentence': original,
              'Meaning': 'manual meaning',
            },
            candidate: <String, String>{
              'Sentence': candidate,
              'Meaning': 'automatic meaning',
              'Unknown': 'ignored',
            },
          );
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog, skipOffstage: false), findsOneWidget);
      expect(find.text('Unknown'), findsNothing);
      expect(find.text(t.card_source_review_conflict_warning), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              glassUnwrap<FilledButton>(
                find.widgetWithText(FilledButton, t.card_source_review_save),
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('anki-source-change-Sentence')),
      );
      await tester.tap(find.text('Sentence'));
      await tester.pumpAndSettle();
      expect(find.text(original), findsOneWidget);
      expect(find.text(candidate), findsOneWidget);
      await tester.tap(find.text(t.card_source_review_save));
      await tester.pumpAndSettle();
      expect(selected, <String, String>{'Sentence': candidate});
    },
  );

  // TODO-1007 健壮性：宿主回调抛错时，action sheet 不能卡在 _busy 进度条无反馈。
  // 这三个用例构造抛错的 mineNew/overwrite，断言：异常不逃逸（无 takeException）、
  // 弹窗仍在（未 pop 关闭）、操作可重试（_busy 已复位 → 按钮重新可点）。

  testWidgets('回归复现：mineNew 抛错时复位 busy + 弹窗保留可重试（不卡进度条）', (tester) async {
    final repo = _FakeRepo(const [MinedNoteRef(noteId: 300, preview: 'A')]);
    int mineNewCalls = 0;
    await tester.pumpWidget(
      _host((context) async {
        await runAnkiMinedCardAction(
          context: context,
          repo: repo,
          expression: 'x',
          reading: '',
          mineNew: () async {
            mineNewCalls++;
            throw StateError('host channel failed');
          },
          overwrite: (noteId) async => (ankiConnect: true, noteId: noteId),
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 点「新增重复卡」→ mineNew 抛错。
    await tester.tap(find.text(t.anki_mined_action_add_duplicate));
    await tester.pumpAndSettle();

    // 异常被吞在 action sheet 内，不向 widget 树逃逸。
    expect(tester.takeException(), isNull);
    expect(mineNewCalls, 1);
    // 弹窗未关闭（仍能看到选项），说明没误 pop。
    expect(find.text(t.anki_mined_action_add_duplicate), findsOneWidget);
    // _busy 已复位：再次点击会再次调用 mineNew（若仍 busy 则 onTap=null 不触发）。
    await tester.tap(find.text(t.anki_mined_action_add_duplicate));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(mineNewCalls, 2, reason: '_busy 必须在失败后复位，否则按钮卡死无法重试');
  });

  testWidgets('回归复现：overwrite 抛错时复位 busy + 弹窗保留可重试', (tester) async {
    final repo = _FakeRepo(const [MinedNoteRef(noteId: 200, preview: 'B')]);
    int overwriteCalls = 0;
    await tester.pumpWidget(
      _host((context) async {
        await runAnkiMinedCardAction(
          context: context,
          repo: repo,
          expression: 'x',
          reading: '',
          mineNew: () async => (ankiConnect: true, noteId: 999),
          overwrite: (noteId) async {
            overwriteCalls++;
            throw StateError('host channel failed');
          },
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(FushiIcons.edit));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(overwriteCalls, 1);
    expect(find.byIcon(FushiIcons.edit), findsOneWidget);
    // 复位后可重试。
    await tester.tap(find.byIcon(FushiIcons.edit));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(overwriteCalls, 2, reason: '_busy 必须在失败后复位');
  });

  testWidgets('回归复现：note viewer overwrite 抛错时复位 busy + 对话框保留', (tester) async {
    final repo = _FakeRepo(
      const [MinedNoteRef(noteId: 300, preview: 'A')],
      fields: const {'Expression': '日本語'},
    );
    int overwriteCalls = 0;
    await tester.pumpWidget(
      _host((context) async {
        await runAnkiMinedCardAction(
          context: context,
          repo: repo,
          expression: '日本語',
          reading: '',
          mineNew: () async => (ankiConnect: true, noteId: 999),
          overwrite: (noteId) async {
            overwriteCalls++;
            throw StateError('host channel failed');
          },
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // 打开 note viewer。
    await tester.tap(find.byIcon(FushiIcons.openInNew));
    await tester.pumpAndSettle();
    // 点对话框里的「覆写」→ overwrite 抛错。
    await tester.tap(find.text(t.anki_mined_action_overwrite));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(overwriteCalls, 1);
    // 对话框仍在（未误 pop），覆写按钮还在 → 可重试。
    expect(find.text(t.anki_mined_action_overwrite), findsOneWidget);
    await tester.tap(find.text(t.anki_mined_action_overwrite));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(overwriteCalls, 2, reason: '_busy 必须在失败后复位');
  });

  // 反馈 -EruTk-rWo：制卡等待期间链路在根导航器上叠出「笔记类型未适配视频」降级提示
  // （fire-and-forget，不等它关）。动作回来后旧实现 `Navigator.pop(result)` 弹的是栈顶
  // 那个 bool 对话框 → 类型错；再点提示的按钮又 pop 到操作对话框 → 第二次类型错，两个
  // 对话框都关不掉。修复后只关自己，提示照常可关、结果照常回传。
  Future<void> runWithFallbackNotice(
    WidgetTester tester, {
    required bool overwrite,
  }) async {
    final repo = _FakeRepo(const [MinedNoteRef(noteId: 300, preview: 'A')]);
    AnkiCardMutationResult? result;
    bool? noticeResult;
    late BuildContext hostContext;

    Future<AnkiCardMutationResult> withNotice(int noteId) async {
      // 与 installAnkiVideoTemplateFallbackNotice 同形：叠在根导航器上、不 await。
      showAppDialog<bool>(
        context: hostContext,
        builder: (dialogContext) => AlertDialog(
          title: const Text('fallback-notice'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('got-it'),
            ),
          ],
        ),
      ).then((bool? v) => noticeResult = v);
      await Future<void>.delayed(Duration.zero);
      return (ankiConnect: true, noteId: noteId);
    }

    await tester.pumpWidget(
      _host((context) async {
        hostContext = context;
        result = await runAnkiMinedCardAction(
          context: context,
          repo: repo,
          expression: 'x',
          reading: '',
          mineNew: () => withNotice(999),
          overwrite: withNotice,
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    if (overwrite) {
      await tester.tap(find.byIcon(FushiIcons.edit));
    } else {
      await tester.tap(find.text(t.anki_mined_action_add_duplicate));
    }
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(result, isNotNull, reason: '操作对话框关掉并回传结果');
    expect(result!.noteId, overwrite ? 300 : 999);
    expect(find.text(t.anki_mined_action_add_duplicate), findsNothing);
    expect(find.text('fallback-notice'), findsOneWidget, reason: '降级提示仍在');

    await tester.tap(find.text('got-it'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('fallback-notice'), findsNothing);
    expect(noticeResult, isFalse);
  }

  testWidgets('反馈 -EruTk-rWo：新增重复卡期间叠出降级提示，两个对话框都能关', (tester) async {
    await runWithFallbackNotice(tester, overwrite: false);
  });

  testWidgets('反馈 -EruTk-rWo：覆写期间叠出降级提示，两个对话框都能关', (tester) async {
    await runWithFallbackNotice(tester, overwrite: true);
  });

  // 反馈 JNyykxvuY9：已制卡 ✓ 的对话框里删卡——次要动作、先确认，不改 ✓ 单击行为。
  group('从 Anki 删除这张卡', () {
    Future<AnkiCardMutationResult?> open(
      WidgetTester tester,
      BaseAnkiRepository repo,
      List<int> mined,
    ) async {
      AnkiCardMutationResult? result;
      await tester.pumpWidget(
        _host((context) async {
          result = await runAnkiMinedCardAction(
            context: context,
            repo: repo,
            expression: '日本語',
            reading: 'にほんご',
            mineNew: () async {
              mined.add(1);
              return (ankiConnect: true, noteId: 999);
            },
            overwrite: (noteId) async => (ankiConnect: true, noteId: noteId),
          );
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('删不了的后端不出删除按钮', (tester) async {
      await open(
        tester,
        _FakeRepo(const [MinedNoteRef(noteId: 300, preview: '日本語 A')]),
        <int>[],
      );
      expect(find.byIcon(FushiIcons.delete), findsNothing);
    });

    testWidgets('点删除先确认；取消回到列表、什么都不删', (tester) async {
      final repo = _DeletableRepo(const [
        MinedNoteRef(noteId: 300, preview: '日本語 A'),
      ]);
      await open(tester, repo, <int>[]);
      await tester.tap(
        find.byKey(const ValueKey<String>('anki-mined-delete-300')),
      );
      await tester.pumpAndSettle();
      expect(find.text(t.anki_mined_delete_confirm_title), findsOneWidget);
      await tester.tap(find.text(t.dialog_cancel));
      await tester.pumpAndSettle();
      expect(repo.deleted, isEmpty);
      expect(find.text('日本語 A'), findsOneWidget);
    });

    testWidgets('删掉其中一张：留在列表、只剩另一张；删光：关对话框、不新增卡', (tester) async {
      final repo = _DeletableRepo(const [
        MinedNoteRef(noteId: 300, preview: '日本語 A'),
        MinedNoteRef(noteId: 200, preview: '日本語 B'),
      ]);
      final List<int> mined = <int>[];
      await open(tester, repo, mined);

      await tester.tap(
        find.byKey(const ValueKey<String>('anki-mined-delete-300')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('anki-mined-delete-confirm')),
      );
      await tester.pumpAndSettle();
      expect(repo.deleted, <int>[300]);
      expect(find.text('日本語 A'), findsNothing);
      expect(find.text('日本語 B'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('anki-mined-delete-200')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('anki-mined-delete-confirm')),
      );
      await tester.pumpAndSettle(const Duration(seconds: 3));
      expect(repo.deleted, <int>[300, 200]);
      expect(find.text(t.anki_mined_card_title), findsNothing);
      expect(mined, isEmpty, reason: '删卡不是制卡');
    });

    testWidgets('删除失败：报错、卡留在列表', (tester) async {
      final repo = _DeletableRepo(const [
        MinedNoteRef(noteId: 300, preview: '日本語 A'),
      ], fail: true);
      await open(tester, repo, <int>[]);
      await tester.tap(
        find.byKey(const ValueKey<String>('anki-mined-delete-300')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('anki-mined-delete-confirm')),
      );
      await tester.pumpAndSettle(const Duration(seconds: 3));
      expect(find.text('日本語 A'), findsOneWidget);
      expect(find.text(t.anki_mined_card_title), findsOneWidget);
    });
  });

  testWidgets('AnkiMobile 删不了：未核实对话框说明要去 AnkiMobile 里删', (tester) async {
    await tester.pumpWidget(
      _host((context) async {
        await runAnkiMinedCardAction(
          context: context,
          repo: _UnverifiableRepo(),
          expression: '見物',
          reading: 'けんぶつ',
          mineNew: () async => (ankiConnect: true, noteId: 1),
          overwrite: (noteId) async => (ankiConnect: true, noteId: noteId),
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(t.anki_mined_delete_in_ankimobile_hint), findsOneWidget);
  });

  // BUG-2051：↗「在 Anki 中打开」的编排已从本文件删除——它不再是 Flutter 层的
  // 事（没有对话框、没有多卡选择框），而是仓库层的一次调用。新的行为守卫在
  // packages/fushi_anki/test/open_word_in_anki_test.dart：判据与查重同源、三态结局。
}
