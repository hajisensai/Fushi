import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/dictionary_import_manager.dart';

/// TODO-609：force 重导决策——纯函数守卫。
///
/// 普通导入（force=false）：完全同名 → alreadyUpToDate（跳过，现有行为不破）。
/// 更新（force=true）：完全同名 → replaceExact（走现成 replaceOldVersion 链路：
/// 删旧目录 + 删旧 meta + 保留 order/hidden/collapsed + 重导带新 revision）。
/// 不同日期版本（base 名同、全名不同）→ replaceOldVersion（与 force 无关，旧行为）。
/// 全新词典 → newDictionary。
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
}
