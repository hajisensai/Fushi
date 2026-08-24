/// 「运行中的这份 Dart 代码来自哪一次构建」——编译期常量，随 AOT 快照
/// （Windows 上就是 `data\app.so`）一起落地。
///
/// 为什么需要它（BUG-1786 / BUG-1831 / BUG-1836 的共同根因）：
///
/// 更新是否真的落地，此前只有两个证据源，两个都会说谎：
///
/// 1. **exe 版本资源**（`PackageInfo.fromPlatform()`）。它和 Dart 代码是**两个
///    文件**：Inno 的回滚保留「被覆盖」的文件、只删「新建」的文件，于是
///    「新 exe + 旧 app.so」的半更新态完全可能落地，版本资源报的是新版本，跑的
///    却是旧代码——BUG-1786 现场连着几天报「更新成功」就是这么来的。
///
///    （**不是**因为版本资源丢后缀：Windows VERSIONINFO 的字符串字段
///    `ProductVersion` 保留完整 build-name，实测本机 `fushi.exe` =
///    `2.2.1-debug.12215+12215`，丢后缀的只是 `FILEVERSION` 那四段数字字段，而
///    package_info 读的正是字符串字段。真正丢后缀的曾是 **beta 通道的 `--build-name`
///    本身**——`release-desktop.yml` 原先只给 debug tag 覆盖 `BUILD_VERSION_NAME`，
///    beta 包的版本名在任何来源里都是裸 `2.2.1`，这条证据在 beta 上直接退化成常量；
///    同一次改动已把版本名对所有版本 tag 派生，与 Android 那条 workflow 对齐。）
/// 2. **Inno 安装日志**。它只在 app 自己发起更新、经 `/LOG=` 传路径时才存在；
///    用户手动双击安装包救援时 Inno 一个字都不写，判据拿不到证据只能判失败
///    （BUG-1836 的真根因就是这一条）。
///
/// 这个常量是第三个证据源，也是唯一一个**和被替换的产物同体**的：它就编译在
/// `app.so` 里，`app.so` 没被换掉它就报旧值，谁也伪造不了。所以
/// 「运行中代码版本 >= 目标版本」是**运行中的代码确实被换成了目标版本**的直接
/// 证据，与谁拉起的安装器、有没有日志都无关。
///
/// 注入方式：构建期 `--dart-define=FUSHI_BUILD_VERSION=<build-name>`，与
/// `flutter build --build-name` 同值、同一处传（守卫测试
/// `test/build/build_version_define_guard_test.dart` 钉死这条配对，漏一处 CI 红）。
library;

/// 构建期注入的完整 build-name，例如 `2.2.1-debug.12215`。
///
/// 没注入时（本地 `flutter run`、`flutter test`、以及**这次改动之前**发布的所有
/// 历史版本）为空串。空串必须当「未知」处理，绝不能当版本号参与比较。
const String kFushiBuildVersionDefine =
    String.fromEnvironment('FUSHI_BUILD_VERSION');

/// 运行中这份 Dart 代码的版本；未注入时返回 `null`（未知，不是 `0.0.0`）。
///
/// 调用方必须把 `null` 当「拿不到这条证据」并退回旧判据，而不是当成「版本不符」。
String? get fushiRunningCodeVersion =>
    normalizeFushiBuildVersion(kFushiBuildVersionDefine);

/// 纯函数版本，供测试注入任意 define 值。
///
/// 只做两件事：去掉首尾空白、把空串折叠成 `null`。**不做**版本号合法性校验——
/// 校验的活归比较函数，这里多一层规则只会制造「合法但被判 null」的特殊情况。
String? normalizeFushiBuildVersion(String rawDefine) {
  final String trimmed = rawDefine.trim();
  return trimmed.isEmpty ? null : trimmed;
}
