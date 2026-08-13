import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：**发布构建失败时必须能看见真错误**，以及别再拿 debug 构建冒充发布验证。
///
/// ## 起因（BUG-1589）
///
/// `release-desktop.yml` 的 Windows 发布构建在 develop 上固定红，而日志里只有：
///
///     Target dart_build failed : error : Building native assets failed.
///     error MSB8066: Custom build for '...' exited with code ...
///
/// MSBuild 把自定义生成步骤的真实报错整个折叠掉了。本机用 `-v` 跑同一条命令才
/// 拿到真正的 CMake 报错——也就是说，**没有 `-v` 就没有根因**，只能反复重跑。
///
/// 同时暴露出更要命的一点：验证构建（`build-multiplatform.yml`）跑的是
/// `flutter build windows --debug`，**不走 AOT**；发布构建跑的是 `--release`。
/// 两者根本不是同一种构建，所以「CI 全绿」从来没有覆盖过发布路径。这和
/// BUG-1588（TMDB key 只注入验证构建、发出去的包没有）是同一种病：**把验证
/// 构建的绿当成发布构建的绿**。
void main() {
  final File releaseDesktop = File('../.github/workflows/release-desktop.yml');
  final File validation = File('../.github/workflows/build-multiplatform.yml');

  test('前置：两条 workflow 都在', () {
    expect(releaseDesktop.existsSync(), isTrue,
        reason: 'expected ${releaseDesktop.absolute.path}');
    expect(validation.existsSync(), isTrue,
        reason: 'expected ${validation.absolute.path}');
  });

  final String releaseText =
      releaseDesktop.existsSync() ? releaseDesktop.readAsStringSync() : '';
  final String validationText =
      validation.existsSync() ? validation.readAsStringSync() : '';

  test('Windows 发布构建带 -v，失败时真错误不会被 MSBuild 折叠掉', () {
    expect(releaseText, contains('flutter build windows --release'),
        reason: 'Windows 发布构建步骤不见了？本守卫失去锚点，先修守卫。');
    expect(
      releaseText,
      contains('flutter build windows --release -v'),
      reason: '发布构建必须带 -v。没有它时 MSBuild 只会吐 '
          '`Target dart_build failed` + `MSB8066` 两行，真正的 CMake/hook 报错'
          '被整个折叠——BUG-1589 就是这样连续两次重跑都拿不到根因。',
    );
  });

  test('Windows 发布构建失败时会把 CMake 日志传成 artifact', () {
    expect(releaseText, contains('CMakeFiles/CMakeError.log'),
        reason: '-v 打的是 flutter 侧；CMake 配置期的报错只在 CMakeOutput.log / '
            'CMakeError.log 里。失败时不捞出来就等于没有。');
    expect(releaseText, contains('if: failure()'),
        reason: '日志上传步骤必须挂 if: failure()，否则成功时白传一份。');
  });

  test('Windows 发布构建前必须抬高 gen_snapshot 栈保留（BUG-1589 根因）', () {
    // -v 落地后第一轮 CI（run 31700342531）拿到的真错误：`aot_elf_release` 阶段
    // gen_snapshot.exe 以 -1073741571 = 0xC00000FD（栈溢出）退出。本仓 AOT 规模
    // 超出其默认栈保留；gen_snapshot 不暴露栈参数，只能 editbin 改二进制头。
    // 本机 SDK 打过同款补丁（flutter upgrade 会冲掉），CI 每次全新 SDK 没有——
    // 所以补丁必须以 workflow 步骤形式存在，且在 release 构建**之前**执行。
    const String stackPatch = '/STACK:134217728';
    expect(releaseText, contains(stackPatch),
        reason: 'release-desktop.yml 里找不到 editbin $stackPatch——'
            'gen_snapshot 栈补丁步骤没了，Windows 发布构建会在 aot_elf_release '
            '阶段以 0xC00000FD 固定红（BUG-1589）。');
    expect(releaseText, contains('gen_snapshot.exe'),
        reason: '栈补丁必须打在 engine artifacts 的 gen_snapshot.exe 上。');
    expect(
      releaseText.indexOf(stackPatch),
      lessThan(releaseText.indexOf('flutter build windows --release')),
      reason: '栈补丁步骤必须排在 Windows release 构建之前，否则首轮构建仍然'
          '用未打补丁的 gen_snapshot。',
    );
  });

  test('验证构建是 debug、发布构建是 release —— 别把前者的绿当后者的绿', () {
    // 这条不是要求「必须不同」，而是把**当前事实**钉在测试里：一旦有人把验证
    // 构建也改成 --release（或反过来），这条会红，逼着改的人回来读上面那段
    // 注释，明白「验证绿 ≠ 发布绿」这个前提是否还成立。
    expect(validationText, contains('flutter build windows --debug'),
        reason: '验证构建原本是 --debug（不走 AOT）。若已改成 --release，'
            '请更新本守卫与 docs/agent/build.md 的相应描述——'
            '「CI 全绿覆盖了发布路径吗」这个问题的答案随之改变。');
  });
}
