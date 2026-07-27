// PR#457 审查 §10-3（用户拍板方案甲）守卫：启动自动迁移的**基线闸门**。
//
// 修复前：只要期望 styling 与 Anki 端不同且 Anki 端是 Hibiki 自有产物，下次
// 启动就静默把用户改过但**没点「应用样式到 Anki」**的客制化推进 Anki。
// 「迁移」应当只在 Hibiki 出厂基线变了时发生，Apply 才是用户内容写进 Anki 的
// 唯一闸门。
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

void main() {
  test('记录的基线 == 当前基线 → 不迁移（用户没点 Apply 就不动 Anki）', () {
    expect(
      shouldAutoMigrateLapisBaseline(
        migratedBaselineSha: currentLapisBaselineSha,
        // Anki 上是「当前基线 + 用户还没 Apply 的客制化之外的旧内容」。
        ankiCss: LapisNoteType.template.css,
      ),
      isFalse,
    );
  });

  test('记录的基线 != 当前基线 → 迁移', () {
    expect(
      shouldAutoMigrateLapisBaseline(
        migratedBaselineSha: 'sha-of-some-older-baseline',
        ankiCss: LapisNoteType.template.css,
      ),
      isTrue,
    );
  });

  test('从未记录过 + Anki 已带当前基线 → 不迁移', () {
    expect(
      shouldAutoMigrateLapisBaseline(
        migratedBaselineSha: null,
        ankiCss: composeLapisCss(fontScalePercent: 125, customCss: '.a{}'),
      ),
      isFalse,
    );
  });

  test('从未记录过 + Anki 还是旧基线 → 迁移（升级路径不被吞掉）', () {
    expect(
      shouldAutoMigrateLapisBaseline(
        migratedBaselineSha: null,
        ankiCss: '/* some older vendored Lapis */\n.card { color: red; }',
      ),
      isTrue,
    );
  });

  test('ankiCssCarriesCurrentLapisBaseline 对 compose 的全部产物成立', () {
    expect(
      ankiCssCarriesCurrentLapisBaseline(
          composeLapisCss(fontScalePercent: 100, customCss: '')),
      isTrue,
    );
    expect(
      ankiCssCarriesCurrentLapisBaseline(
          composeLapisCss(fontScalePercent: 150, customCss: '.x{}')),
      isTrue,
    );
    expect(ankiCssCarriesCurrentLapisBaseline('.card { }'), isFalse);
  });
}
