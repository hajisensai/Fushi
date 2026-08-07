import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/galgame_system_ui_filter.dart';

/// galgame 文本 hook「系统 UI 文字 vs 台词」过滤守卫（[isGalgameSystemUiLine]）。
///
/// 正样本取自真机实证（KiriKiri / Otomeki，`FUSHI_LUNA_DIAG` lunadiag 采样）里从读/存档界面
/// 漏进来的系统串；负样本取自同一采样里的真台词。根契约：系统串被剔除、真台词一律放行。
void main() {
  group('系统 UI 文字（实测串）被判定为系统，不进查词面板', () {
    const List<String> systemLines = <String>[
      // 载入确认句（可能多槽拼接）。
      'No.06のデータをロードしますNo.05のデータをロードします',
      'No.05のデータをロードします',
      'このデータをセーブします',
      // 存档槽号列表（含全角章节号）。
      'No.16No.16No.16No.13No.13No.13No.10No.10No.10第４章第４章第４章No.06No.06No.06第３章',
      // 存档时间戳（date+time 拼接 / 片段）。
      '2025/01/1921:58:14',
      '722:17:392025/01/1720:28:112025/01/17',
    ];
    for (final String line in systemLines) {
      test('剔除: ${line.length > 24 ? '${line.substring(0, 24)}…' : line}', () {
        expect(isGalgameSystemUiLine(line), isTrue);
      });
    }
  });

  group('真台词（实测串）一律放行，不误伤', () {
    const List<String> dialogueLines = <String>[
      'この世界は、ろくなものじゃない。',
      '「えっと……何を？」',
      '砲弾が頭上を飛ぶ音と、爆発の衝撃。',
      '内臓を震わす重低音に、身体がすくみ上がった。',
      '「ハハッ！　良いツラすんじゃねぇか」',
      // 含普通「セーブ/ロード」词但非系统确认句式的口语（不该误伤）。
      'セーブしておいてよかった。',
      // 含数字的真台词（去数字后仍有实义文字 → 放行）。
      '午後3時に集合ね。',
      // 含「章」字的真台词（第N章模式不整行匹配 → 放行）。
      'この文章は難しい。',
    ];
    for (final String line in dialogueLines) {
      test('放行: $line', () {
        expect(isGalgameSystemUiLine(line), isFalse);
      });
    }
  });

  group('边界', () {
    test('空 / 纯空白 → 非系统（交由上游其它过滤）', () {
      expect(isGalgameSystemUiLine(''), isFalse);
      expect(isGalgameSystemUiLine('   '), isFalse);
    });

    test('前后空白不影响判定', () {
      expect(isGalgameSystemUiLine('  No.05のデータをロードします  '), isTrue);
      expect(isGalgameSystemUiLine('  この世界は。  '), isFalse);
    });
  });

  // 回归守卫：活代码的文本 poll 路径（GalHookSessionController）必须真的接了这个过滤器。
  // PR#295 曾把过滤器留在（现已删除的）死代码 GalgameSessionController 里、新路径漏接，
  // 导致系统 UI 文字漏进查词面板——源码扫描确保 appendLine 之前调用了 isGalgameSystemUiLine，防回归。
  test('GalHookSessionController 的 poll 路径接了 isGalgameSystemUiLine 过滤', () {
    final File controller = File(
      'lib/src/mining/gal_hook_session_controller.dart',
    );
    expect(controller.existsSync(), isTrue,
        reason: '找不到 gal_hook_session_controller.dart，路径变更请更新本守卫');
    final String src = controller.readAsStringSync();
    expect(
      src.contains('isGalgameSystemUiLine(line.text)'),
      isTrue,
      reason: '活代码 poll 路径必须在 appendLine 前调用 isGalgameSystemUiLine 剔除系统 UI 文字',
    );
  });
}
