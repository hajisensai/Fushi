import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';

// 库页布局 2026-11-12 删掉「规整色块」档（落库值 `blocks`），只剩拼贴与封面网格。
// 偏好键与其余落库值冻结不改；已存的 `blocks` 读到时落到拼贴。
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
}
