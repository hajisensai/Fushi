import 'package:flutter_test/flutter_test.dart';

import '../helpers/android_vendored_libmpv.dart';

/// BUG-3325 / BUG-2032：Android 随包 libmpv 必须编进 Lua。
///
/// 没编 Lua 时 `load-script` 照样返回成功，用户导入的脚本静默不跑（#2014）。
/// 这里读的是真实打包进 jar 的 `libmpv.so` 字节：meson 构建串里的 `-Dlua=lua`
/// 说明配置要了 Lua，`Lua 5.2` 是静态链进来的 Lua 运行时自己的 `_VERSION`
/// 串——两样都在才算编进去了，换回 `-Dlua=disabled` 的旧 jar 这里就红。
void main() {
  test('Android jar 的 libmpv 全部编了 Lua 5.2', () {
    for (final ({String abi, String contents, String codec}) artifact
        in verifiedAndroidLibmpv()) {
      expect(artifact.contents, contains('-Dlua=lua '), reason: artifact.abi);
      expect(
        artifact.contents,
        isNot(contains('-Dlua=disabled')),
        reason: artifact.abi,
      );
      expect(
        artifact.contents,
        contains('\u0000Lua 5.2\u0000'),
        reason: artifact.abi,
      );
    }
  });
}
