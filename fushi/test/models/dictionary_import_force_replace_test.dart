import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:path/path.dart' as path;

import 'package:fushi/src/models/dictionary_import_manager.dart';
import 'package:fushi/src/models/dictionary_repository.dart';

/// TODO-609：force 重导决策——纯函数守卫。
///
/// 普通导入（force=false）：完全同名 → alreadyUpToDate（跳过，现有行为不破）。
/// 更新（force=true）：完全同名 → replaceExact（走现成 replaceOldVersion 链路：
/// 删旧目录 + 删旧 meta + 保留 order/hidden/collapsed + 重导带新 revision）。
/// 不同日期版本（base 名同、全名不同）→ replaceOldVersion（与 force 无关，旧行为）。
/// 全新词典 → newDictionary。
///
/// BUG-1595：更新入口显式替换目标（hasReplaceTarget / replaceTarget）——被点击的
/// 词典就是被替换的词典，新包 title 变化（标题携带版本号等，不匹配
/// findUpdatable 的 [YYYY-MM-DD] 尾缀）不再把「更新」误判成「追加」两版并存。
Dictionary _dict({
  required String name,
  int order = 0,
  List<String> hiddenLanguages = const <String>[],
  List<String> collapsedLanguages = const <String>[],
}) {
  return Dictionary(
    name: name,
    formatKey: 'yomichan',
    order: order,
    type: DictionaryType.term,
    metadata: const <String, String>{},
    hiddenLanguages: hiddenLanguages,
    collapsedLanguages: collapsedLanguages,
  );
}

void main() {
  group('DictionaryImportManager.decideUpdate', () {
    test('force=false + 完全同名 → alreadyUpToDate（跳过，不破旧行为）', () {
      expect(
        DictionaryImportManager.decideUpdate(
          hasExactName: true,
          hasUpdatableVersion: false,
          force: false,
        ),
        UpdateDecision.alreadyUpToDate,
      );
    });

    test('force=true + 完全同名 → replaceExact（强制重导）', () {
      expect(
        DictionaryImportManager.decideUpdate(
          hasExactName: true,
          hasUpdatableVersion: false,
          force: true,
        ),
        UpdateDecision.replaceExact,
      );
    });

    test('不同日期版本（base 同名）→ replaceOldVersion（与 force 无关）', () {
      expect(
        DictionaryImportManager.decideUpdate(
          hasExactName: false,
          hasUpdatableVersion: true,
          force: false,
        ),
        UpdateDecision.replaceOldVersion,
      );
      expect(
        DictionaryImportManager.decideUpdate(
          hasExactName: false,
          hasUpdatableVersion: true,
          force: true,
        ),
        UpdateDecision.replaceOldVersion,
      );
    });

    test('全新词典 → newDictionary', () {
      expect(
        DictionaryImportManager.decideUpdate(
          hasExactName: false,
          hasUpdatableVersion: false,
          force: false,
        ),
        UpdateDecision.newDictionary,
      );
    });

    test('BUG-1595: hasReplaceTarget 压过一切按 title 的判定 → 恒 replaceExact', () {
      // 用户症状原型：标题携带版本号（「V2026.08.11」→「V2026.08.13」），既不完全
      // 同名也不匹配日期尾缀 → 旧逻辑 newDictionary（追加两版并存）；显式目标下
      // 必须是 replaceExact（替换被点击的那本）。
      for (final bool exact in <bool>[false, true]) {
        for (final bool updatable in <bool>[false, true]) {
          for (final bool force in <bool>[false, true]) {
            expect(
              DictionaryImportManager.decideUpdate(
                hasExactName: exact,
                hasUpdatableVersion: updatable,
                force: force,
                hasReplaceTarget: true,
              ),
              UpdateDecision.replaceExact,
              reason: 'exact=$exact updatable=$updatable force=$force',
            );
          }
        }
      }
    });

    test('BUG-1595: hasReplaceTarget 默认 false → 旧决策完全不变', () {
      // 不传 hasReplaceTarget（普通导入/批量导入入口）与传 false 等价，四态语义
      // 由上面的既有用例锁定；这里锁「默认值就是 false」这个契约本身。
      expect(
        DictionaryImportManager.decideUpdate(
          hasExactName: false,
          hasUpdatableVersion: false,
          force: false,
        ),
        UpdateDecision.newDictionary,
      );
    });

    test('完全同名优先于不同版本（exact 命中即 exact 分支）', () {
      // force=false：精确同名优先 → alreadyUpToDate。
      expect(
        DictionaryImportManager.decideUpdate(
          hasExactName: true,
          hasUpdatableVersion: true,
          force: false,
        ),
        UpdateDecision.alreadyUpToDate,
      );
      // force=true：精确同名优先 → replaceExact。
      expect(
        DictionaryImportManager.decideUpdate(
          hasExactName: true,
          hasUpdatableVersion: true,
          force: true,
        ),
        UpdateDecision.replaceExact,
      );
    });
  });

  group('DictionaryImportManager.mergeSourceMetadata (W-2)', () {
    test('revision 永远取 index.json（override 的 revision 被忽略）', () {
      final Map<String, String> m = DictionaryImportManager.mergeSourceMetadata(
        <String, String>{'revision': 'pkg-2026-06-20'},
        <String, String>{'revision': 'stale-override', 'downloadUrl': 'u'},
      );
      expect(m['revision'], 'pkg-2026-06-20');
      expect(m['downloadUrl'], 'u');
    });

    test('override 的 isUpdatable 压过包内 index.json 的 false（修复二次更新缺口）', () {
      // 包内 index.json 不声明 isUpdatable → glaze 写回 false；更新链路传 'true'
      // 的 override 必须胜出，否则更新一次后丢失可更新性。
      final Map<String, String> m = DictionaryImportManager.mergeSourceMetadata(
        <String, String>{'revision': 'r2', 'isUpdatable': 'false'},
        <String, String>{
          'isUpdatable': 'true',
          'indexUrl': 'https://x/index.json',
          'downloadUrl': 'https://x/d.zip',
        },
      );
      expect(m['isUpdatable'], 'true');
      expect(m['indexUrl'], 'https://x/index.json');
      expect(m['downloadUrl'], 'https://x/d.zip');
      expect(m['revision'], 'r2');
    });

    test('override 缺某字段时回退包内 index.json', () {
      final Map<String, String> m = DictionaryImportManager.mergeSourceMetadata(
        <String, String>{
          'revision': 'r3',
          'isUpdatable': 'true',
          'indexUrl': 'pkg-index',
        },
        <String, String>{'downloadUrl': 'override-dl'},
      );
      // 包内声明的 isUpdatable/indexUrl 在 override 没覆盖时保留。
      expect(m['isUpdatable'], 'true');
      expect(m['indexUrl'], 'pkg-index');
      expect(m['downloadUrl'], 'override-dl');
    });

    test('sourceOverride 为 null → 等同包内 index.json', () {
      final Map<String, String> m = DictionaryImportManager.mergeSourceMetadata(
        <String, String>{'revision': 'r4', 'isUpdatable': 'true'},
        null,
      );
      expect(m, <String, String>{'revision': 'r4', 'isUpdatable': 'true'});
    });

    test('两者都空 → 空 Map（旧词典向后兼容）', () {
      expect(
        DictionaryImportManager.mergeSourceMetadata(
            const <String, String>{}, null),
        isEmpty,
      );
    });
  });

  group('BUG-1595: resolveAndRemoveReplaced（显式替换目标的旧本清理）', () {
    late Directory resourceDir;
    late FushiDatabase db;
    late DictionaryRepository repo;
    late DictionaryImportManager manager;

    /// 建一本已导入词典的磁盘目录（放一个占位文件，断言删除时连内容一起没了）。
    Directory dirFor(String name) {
      final Directory d = Directory(path.join(resourceDir.path, name))
        ..createSync(recursive: true);
      File(path.join(d.path, 'term_bank_1.json')).writeAsStringSync('[]');
      return d;
    }

    setUp(() async {
      resourceDir = Directory.systemTemp.createTempSync('hibiki_replace_');
      db =
          FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
      repo = DictionaryRepository(db);
      await repo.loadFromDb();
      manager = DictionaryImportManager(
        dictRepo: repo,
        resourceDirectory: resourceDir,
        formats: const <String, DictionaryFormat>{},
      );
    });

    tearDown(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      repo.dispose();
      await db.close();
      if (resourceDir.existsSync()) resourceDir.deleteSync(recursive: true);
    });

    test('异名替换（用户症状原型）：新包标题版本号变化仍替换被点击词典，继承设置', () async {
      const String oldName = 'OALDPEX En-Cn 精装版 V2026.08.11';
      const String newName = 'OALDPEX En-Cn 精装版 V2026.08.13';
      final Dictionary old = _dict(
        name: oldName,
        order: 3,
        hiddenLanguages: <String>['en'],
        collapsedLanguages: <String>['zh'],
      );
      repo.persistDictionary(old);
      final Directory oldDir = dirFor(oldName);

      // 旧的按 title 决策对这个形状确实误判 newDictionary——这就是两版并存根因。
      expect(
        DictionaryImportManager.decideUpdate(
          hasExactName: repo.hasDictionaryNamed(newName),
          hasUpdatableVersion: repo.findUpdatable(newName) != null,
          force: true,
        ),
        UpdateDecision.newDictionary,
      );

      final Dictionary? preserved = await manager.resolveAndRemoveReplaced(
        newName: newName,
        decision: UpdateDecision.replaceExact,
        replaceTarget: old,
      );

      // 继承来源就是被点击的旧本（order/hidden/collapsed 供新词典落库时保留）。
      expect(preserved, isNotNull);
      expect(preserved!.name, oldName);
      expect(preserved.order, 3);
      expect(preserved.hiddenLanguages, <String>['en']);
      expect(preserved.collapsedLanguages, <String>['zh']);
      // 旧本已删干净：meta 不在、磁盘目录不在 → 不会两版并存。
      expect(repo.hasDictionaryNamed(oldName), isFalse);
      expect(oldDir.existsSync(), isFalse);
    });

    test('同名替换（在线更新 title 不变）：与 replaceExact 同待遇', () async {
      const String name = 'JMdict';
      final Dictionary old = _dict(name: name, order: 7);
      repo.persistDictionary(old);
      final Directory oldDir = dirFor(name);

      final Dictionary? preserved = await manager.resolveAndRemoveReplaced(
        newName: name,
        decision: UpdateDecision.replaceExact,
        replaceTarget: old,
      );

      expect(preserved!.order, 7);
      expect(repo.hasDictionaryNamed(name), isFalse);
      expect(oldDir.existsSync(), isFalse);
    });

    test('撞名收尾：新包 title 恰好等于另一本已存词典 → 两本都删、设置继承自目标', () async {
      final Dictionary target = _dict(name: '旧标题词典', order: 2);
      final Dictionary colliding = _dict(name: '新标题词典', order: 5);
      repo.persistDictionary(target);
      repo.persistDictionary(colliding);
      final Directory targetDir = dirFor(target.name);
      final Directory collidingDir = dirFor(colliding.name);

      final Dictionary? preserved = await manager.resolveAndRemoveReplaced(
        newName: colliding.name,
        decision: UpdateDecision.replaceExact,
        replaceTarget: target,
      );

      // 继承的是被点击的目标（order=2），不是撞名的那本。
      expect(preserved!.name, target.name);
      expect(preserved.order, 2);
      // 两本旧的都删干净——发布/upsert 不会留下指向被覆盖目录的孤儿 meta。
      expect(repo.hasDictionaryNamed(target.name), isFalse);
      expect(repo.hasDictionaryNamed(colliding.name), isFalse);
      expect(targetDir.existsSync(), isFalse);
      expect(collidingDir.existsSync(), isFalse);
    });

    test('无显式目标：replaceExact 按精确同名反查（TODO-609 旧行为不变）', () async {
      final Dictionary old = _dict(name: 'Pixiv', order: 4);
      repo.persistDictionary(old);
      final Directory oldDir = dirFor('Pixiv');

      final Dictionary? preserved = await manager.resolveAndRemoveReplaced(
        newName: 'Pixiv',
        decision: UpdateDecision.replaceExact,
        replaceTarget: null,
      );

      expect(preserved!.name, 'Pixiv');
      expect(preserved.order, 4);
      expect(repo.hasDictionaryNamed('Pixiv'), isFalse);
      expect(oldDir.existsSync(), isFalse);
    });

    test('无显式目标：replaceOldVersion 走 findUpdatable（日期尾缀旧行为不变）', () async {
      final Dictionary old = _dict(name: 'JMdict [2026-05-17]', order: 1);
      repo.persistDictionary(old);
      final Directory oldDir = dirFor(old.name);

      final Dictionary? preserved = await manager.resolveAndRemoveReplaced(
        newName: 'JMdict [2026-05-19]',
        decision: UpdateDecision.replaceOldVersion,
        replaceTarget: null,
      );

      expect(preserved!.name, 'JMdict [2026-05-17]');
      expect(repo.hasDictionaryNamed(old.name), isFalse);
      expect(oldDir.existsSync(), isFalse);
    });

    test('非替换类决策：不删任何东西、返 null', () async {
      final Dictionary old = _dict(name: 'KANJIDIC', order: 6);
      repo.persistDictionary(old);
      final Directory oldDir = dirFor('KANJIDIC');

      for (final UpdateDecision decision in <UpdateDecision>[
        UpdateDecision.newDictionary,
        UpdateDecision.alreadyUpToDate,
      ]) {
        final Dictionary? preserved = await manager.resolveAndRemoveReplaced(
          newName: 'KANJIDIC',
          decision: decision,
          replaceTarget: null,
        );
        expect(preserved, isNull, reason: '$decision');
      }
      expect(repo.hasDictionaryNamed('KANJIDIC'), isTrue);
      expect(oldDir.existsSync(), isTrue);
    });

    test('目标目录已不存在（只剩 meta）：容忍缺目录，仍删 meta', () async {
      final Dictionary old = _dict(name: 'GhostDict', order: 9);
      repo.persistDictionary(old);
      // 故意不建磁盘目录。

      final Dictionary? preserved = await manager.resolveAndRemoveReplaced(
        newName: 'GhostDict V2',
        decision: UpdateDecision.replaceExact,
        replaceTarget: old,
      );

      expect(preserved!.name, 'GhostDict');
      expect(repo.hasDictionaryNamed('GhostDict'), isFalse);
    });
  });
}
