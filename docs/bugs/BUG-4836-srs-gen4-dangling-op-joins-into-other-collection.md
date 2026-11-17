## BUG-4836 · 新代同库 A 拿 B 的实体 ID 写下的悬空操作，A 的集合并入 B 之后改到 B 的笔记 / 卡片（BUG-4626 新代并入场景）
- **报告**：2026-11-18（SRS gen4 第四波 G9-5d 复核发现；交接 `docs/specs/2026-11-15-srs-gen4-handoff.md` §26 T1 节「BUG-4626 判据在新代放宽」
  与「第四波 G9-5 续」节「没做 / 交出去」）。归属：G9 身份 / 设计（内核取舍），本条只登记，未修。
- **真实性**：✅ 真 bug（2026-11-17 在分支 `pr/srs-gen4-g9-5d-link-flow` 上实测：下面的复现用例 `flutter test` exit 1，1 条执行，
  `Expected: '鳥'` / `Actual: '被 A 改'`）。
  - 场景：同一份 `srs4.db` 里有 A、B 两份 profile（两个集合）。A 的 store 拿 B 的笔记 / 卡片 ID 改字段、标签、旗标、暂停。
    协议 3 在追加前拒绝（BUG-4626 的修复，`ownership.rs` `foreign`）；新代不拒绝，落成 A 集合日志里指向「本集合不存在的 ID」
    的悬空操作，B 当时看不到。之后另一台设备上的 B 经 `.fushisrs` 确认并入 A 的集合（`srsExportFushiSrs` → `srsImportFushiSrs`，
    内核 `import` + `collection_adopt`）——设计稿 2026-11-11 §2「ID 不再按 uid 加盐、并入 = 操作并集」，这些悬空操作随并集
    对 B 的同名实体生效：B 的笔记字段变成 A 写的值。
  - 根因（写入口不设闸）：`native/fushi_fsrs/src/store/gen4/cmd/writes.rs:31`（文件头「没有跨 profile 的归属判定」：按
    「别的集合的实体在这里根本不可见」放掉了协议 3 的 `ownership.rs` 闸）与 `:886`（`apply`：直接 `apply_in` 追加，不核对
    实体是否属于本集合 / 本库别的集合）。
  - 根因（并入是无条件并集）：`native/fushi_fsrs/src/store/gen4/identity.rs:430`（`adopt_foreign`，`Joined` 后两个集合的操作
    全部并进同一个派生层）、`:572`（`absorb_foreign`，半截并入收尾同口径）；`.fushisrs` 并入入口
    `native/fushi_fsrs/src/store/gen4/cmd/fushisrs.rs:415`（`import`）。
- **[ ] ① 未修复** — 两种修法，都动内核，需 G9 身份 / 设计定：
  1. **写入口归属闸**：`apply` / `sched` / 清除在追加前拒绝「本集合没有、本库别的集合有」的实体 ID（与协议 3 同语义：别人的 ID
     对调用方表现为不存在）。需要跨 `col` 按实体查的索引——新代库 schema 改动（升 `SCHEMA`、进 `PLANNER_STATS` / EXPLAIN 测试）。
     只能挡本库同库写入，挡不住别的设备上早已写下的悬空操作。
  2. **并入时丢悬空操作**：并入（`adopt_foreign` / `absorb_foreign` 的 `Joined`）时，丢掉「改的是并入方集合当时不存在的实体」的
     操作。改并集语义：要定「当时」的判据（按因果 / 按并入时刻）、几台设备并入结果要一致（摘要对拍），并核对导入同批先后到、
     换笔记类型给未生成的卡写血统这类合法的「先写后有」不被误丢。
- **[ ] ② 未加自动化测试** — 复现用例没入库（不提交红），原文如下，修复时放进
  `packages/fushi_engine/test/srs/srs_profile_ownership_merge_test.dart`（同目录 `support/srs_fake_engine.dart`、
  `support/srs_test_storage.dart`）：

```dart
// BUG-4626 在新代的并入场景（交接 T1 节「待 G9-5 确认」，srs_profile_ownership_test.dart 文件头）：同库两份 profile
// 时 A 拿 B 的实体 ID 下手，新代不在追加前拒绝，而是在 A 自己的集合里落一条指向「不存在的 ID」的悬空操作。设计稿
// 2026-11-11 §2 下 ID 不再按 uid 加盐、并入 = 操作并集，所以要钉住：A 的集合之后并进 B 的集合（另一台设备上的 B 确认
// 导入 A 的 `.fushisrs`，内核 `import` + `collection_adopt`），这些悬空操作不能对 B 的同名实体生效。
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_fushisrs.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'support/srs_fake_engine.dart';
import 'support/srs_test_storage.dart';

const String kA = '01928c3e-0000-7000-8000-0000000000a1';
const String kB = '01928c3e-0000-7000-8000-0000000000b2';

Future<SrsDbStore> _open(SrsStorage st, String uid, String device) =>
    SrsDbStore.open(
      core: st.core,
      profileUid: uid,
      deviceId: device,
      engine: const SrsFakeEngine(),
    );

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('A 写 B 的 ID（同库，落成悬空操作）→ A 的集合并进 B → B 的笔记与卡片不被改', () async {
    // 本机：A 与 B 两份 profile 同库。B 的数据在 B 的集合里。
    final SrsStorage local = await openTestSrsStorage();
    final SrsDbStore a = await _open(local, kA, 'dev-local');
    final SrsDbStore b = await _open(local, kB, 'dev-local');
    final String expression = srsLapisFieldId(kB, 'Expression');
    final String note = await b.createNote(
      noteTypeId: b.lapisNoteTypeId,
      fieldsById: <String, String>{expression: '鳥'},
      tags: <String>['tag-鳥'],
    );
    final String card = (await b.cardsOfNote(note)).single.id;

    // A 拿 B 的 ID 下手：新代不拒绝，记在 A 自己的集合里（B 看不到）。
    await a.editField(
      SrsEntityKind.note,
      note,
      SrsFieldKeys.noteField(expression),
      '被 A 改',
    );
    await a.editFields(SrsEntityKind.note, note, <String, Object?>{
      SrsFieldKeys.noteTags: <String>['串了'],
    });
    await a.setFlag(card, 3);
    await a.setSuspended(card, true);
    expect((await b.note(note))!.field(expression), '鳥');

    // 另一台设备上的 B（同一个 B 集合）：先拿到 B 的全部数据。
    final Directory tmp = Directory.systemTemp.createTempSync('srs_4626_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final File bFile = File('${tmp.path}${Platform.pathSeparator}b.fushisrs');
    await srsExportFushiSrs(b, bFile, withMedia: false);
    final SrsStorage remote = await openTestSrsStorage();
    final SrsDbStore b2 = await _open(remote, kB, 'dev-remote');
    await srsImportFushiSrs(
      b2,
      bFile,
      confirmForeign: (SrsFushiSrsForeign _) async => true,
    );
    expect((await b2.note(note))!.field(expression), '鳥');

    // 用户在那台设备上确认把 A 的集合并进来（导入 A 的 `.fushisrs`：另一个集合，确认后并入）。
    final File aFile = File('${tmp.path}${Platform.pathSeparator}a.fushisrs');
    await srsExportFushiSrs(a, aFile, withMedia: false);
    bool asked = false;
    await srsImportFushiSrs(
      b2,
      aFile,
      confirmForeign: (SrsFushiSrsForeign _) async => asked = true,
    );
    expect(asked, isTrue, reason: 'A 的集合是另一个集合，要问过用户才并入');

    final SrsNoteView? merged = await b2.note(note);
    expect(merged, isNotNull);
    expect(merged!.field(expression), '鳥', reason: 'A 的悬空修改不能改到 B 的笔记');
    expect(merged.tags, <String>['tag-鳥']);
    final SrsCardCacheRow row = (await b2.cardRow(card))!;
    expect(row.flag, 0);
    expect(row.suspended, isFalse);
  });
}
```

- **备注**：
  - 同库两集合互不并入时没有后果（A 的悬空操作只在 A 的集合里，B 看不到）；只有 A 的集合之后并进 B（本机或别的设备确认并入、
    `.fushisrs` 导入）才生效。
  - BUG-4626（协议 3）的修复与测试不受影响；本条是新代换代后同一前提的新场景，单独一条以免改动已结案的 4626。
