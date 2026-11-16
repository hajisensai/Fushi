import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';

// 库页布局 2026-11-12 删掉「规整色块」档（落库值 `blocks`），只剩拼贴与封面网格。
// 偏好键与其余落库值冻结不改；已存的 `blocks` 读到时落到拼贴。
// G1（2026-11-15）：没选过布局时按本安装的出厂值读——新安装拼贴、升级上来的老
// 用户封面网格（ShellLayoutInstallDefault）。C1：色块摆放默认一律规整。
void main() {
  test('库页布局只剩拼贴与封面网格', () {
    expect(ShellContentLayout.values, <ShellContentLayout>[
      ShellContentLayout.collage,
      ShellContentLayout.grid,
    ]);
  });

  test('已存的 blocks 读成拼贴，其余落库值不变', () {
    expect(ShellContentLayout.fromPref('blocks'), ShellContentLayout.collage);
    expect(ShellContentLayout.fromPref('collage'), ShellContentLayout.collage);
    expect(ShellContentLayout.fromPref('grid'), ShellContentLayout.grid);
    expect(ShellContentLayout.fromPref(''), ShellContentLayout.collage);
    expect(ShellContentLayout.fromPref(null), ShellContentLayout.collage);
    expect(ShellContentLayout.collage.prefValue, 'collage');
    expect(ShellContentLayout.grid.prefValue, 'grid');
  });

  test('没选过 / 未知值落到 fallback；blocks 与显式值不受 fallback 影响', () {
    const ShellContentLayout grid = ShellContentLayout.grid;
    expect(ShellContentLayout.fromPref('', fallback: grid), grid);
    expect(ShellContentLayout.fromPref(null, fallback: grid), grid);
    expect(ShellContentLayout.fromPref('bogus', fallback: grid), grid);
    expect(
      ShellContentLayout.fromPref('blocks', fallback: grid),
      ShellContentLayout.collage,
    );
    expect(
      ShellContentLayout.fromPref('collage', fallback: grid),
      ShellContentLayout.collage,
    );
  });

  group('ShellLayoutInstallDefault', () {
    test('新安装：出厂拼贴、不弹选择框', () {
      final ShellLayoutInstallDefault d = ShellLayoutInstallDefault.settle(
        existingInstall: false,
        layoutChosen: false,
      );
      expect(d, ShellLayoutInstallDefault.fresh);
      expect(d.layout, ShellContentLayout.collage);
      expect(d.choicePending, isFalse);
    });

    test('升级上来、没选过布局：出厂封面网格、弹一次', () {
      final ShellLayoutInstallDefault d = ShellLayoutInstallDefault.settle(
        existingInstall: true,
        layoutChosen: false,
      );
      expect(d, ShellLayoutInstallDefault.upgradeChoicePending);
      expect(d.layout, ShellContentLayout.grid);
      expect(d.choicePending, isTrue);
    });

    test('升级前就选过布局：不弹', () {
      final ShellLayoutInstallDefault d = ShellLayoutInstallDefault.settle(
        existingInstall: true,
        layoutChosen: true,
      );
      expect(d, ShellLayoutInstallDefault.upgrade);
      expect(d.layout, ShellContentLayout.grid);
      expect(d.choicePending, isFalse);
    });

    test('落库值往返，未知 / 缺失为 null（还没判定）', () {
      for (final ShellLayoutInstallDefault d
          in ShellLayoutInstallDefault.values) {
        expect(ShellLayoutInstallDefault.fromPref(d.prefValue), d);
      }
      expect(ShellLayoutInstallDefault.fromPref(null), isNull);
      expect(ShellLayoutInstallDefault.fromPref('bogus'), isNull);
      expect(
        ShellLayoutInstallDefault.prefKey,
        'shell_content_layout_install_default',
      );
    });
  });

  test('C1：色块摆放没选过时一律规整（拼贴不再默认散落）', () {
    for (final ShellContentLayout layout in ShellContentLayout.values) {
      expect(
        ShellBlockArrangement.defaultFor(layout),
        ShellBlockArrangement.aligned,
      );
      expect(
        ShellBlockArrangement.fromPref(null, layout: layout),
        ShellBlockArrangement.aligned,
      );
    }
  });
}
