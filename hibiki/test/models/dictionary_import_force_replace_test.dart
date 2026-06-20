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
}
