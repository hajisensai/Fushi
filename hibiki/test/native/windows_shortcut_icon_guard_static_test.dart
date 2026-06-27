import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-901 源码守卫：Windows 桌面换图标后同步 .lnk 快捷方式图标的链路在位。
///
/// 链路：Dart `syncWindowsShortcutIcons` 编码多尺寸 .ico + 落盘 → 经
/// `app.hibiki/window` channel 的 `setShortcutIcon`（入参 key `iconPath`）→ 原生
/// `ApplyShortcutIcon` 用 IShellLink + IPersistFile 改写桌面 / 开始菜单 .lnk 的
/// IconLocation。删掉任一环即红。
void main() {
  String read(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), isTrue, reason: '文件不存在：$rel');
    return f.readAsStringSync().replaceAll('\r\n', '\n');
  }

  test('native flutter_window.cpp 含 setShortcutIcon + IShellLink 实现', () {
    final String src = read('windows/runner/flutter_window.cpp');

    // channel 分支：method 名 + 正确入参 key（iconPath，而非 setWindowIcon 的 path）。
    expect(src.contains('"setShortcutIcon"'), isTrue,
        reason: 'channel 必须处理 setShortcutIcon');
    expect(src.contains('flutter::EncodableValue("iconPath")'), isTrue,
        reason: 'setShortcutIcon 入参 key 必须是 iconPath（别混 setWindowIcon 的 path）');

    // 真正写穿 .lnk：必须用 IShellLink + IPersistFile，且先 Load 后 Save（保留 target）。
    expect(src.contains('CLSID_ShellLink'), isTrue,
        reason: '必须 CoCreateInstance(CLSID_ShellLink) 改 .lnk');
    expect(src.contains('SetIconLocation('), isTrue,
        reason: '必须调 IShellLink::SetIconLocation 改图标');
    final int loadIdx = src.indexOf('->Load(');
    final int saveIdx = src.indexOf('->Save(');
    expect(loadIdx >= 0 && saveIdx > loadIdx, isTrue,
        reason:
            '必须先 IPersistFile::Load 现有 .lnk 再 Save（保留 target/args/workdir）');

    // 桌面 + 开始菜单两处，且用 KnownFolder 解析（不拼环境变量，兼容 OneDrive 重定向）。
    expect(src.contains('FOLDERID_Desktop'), isTrue, reason: '必须同步桌面快捷方式');
    expect(src.contains('FOLDERID_Programs'), isTrue, reason: '必须同步开始菜单快捷方式');
    // TODO-901 C1 回归守卫（load-bearing）：开始菜单 .lnk 落在程序组子文件夹
    // 内，相对路径必须是 Hibiki 子目录 + Hibiki.lnk，而不是 Programs 根下的
    // 裸 Hibiki.lnk（{group} = {autoprograms}+程序组名，含 Hibiki 子目录）。
    // 若把开始菜单那一支的相对路径改回根目录形式，GetFileAttributesW 恒 INVALID
    // → 软跳过 → 换图标时开始菜单图标永不更新。锁住整条 FOLDERID_Programs 调用
    // 连同其子目录实参，改回根目录即红（用 RegExp 匹配整段调用，避免被注释里的
    // 示例文本误满足）。
    expect(
        RegExp(r'HibikiShortcutInFolder\(\s*FOLDERID_Programs\s*,\s*'
                r'L"Hibiki\\\\Hibiki\.lnk"')
            .hasMatch(src),
        isTrue,
        reason: r'开始菜单 .lnk 必须拼成程序组 Hibiki 子文件夹下的 Hibiki.lnk'
            r'（FOLDERID_Programs + Hibiki\Hibiki.lnk），不能用 Programs 根下的裸 Hibiki.lnk');
    expect(src.contains('SHGetKnownFolderPath('), isTrue,
        reason: '路径必须用 SHGetKnownFolderPath 解析（兼容 OneDrive 重定向桌面）');

    // 改完通知 shell 重读图标。
    expect(src.contains('SHChangeNotify('), isTrue,
        reason: '改完 .lnk 必须 SHChangeNotify 让 shell 重读图标');
  });

  test('CMakeLists 链接 ole32 + shell32（IShellLink/KnownFolder 依赖）', () {
    final String cmake = read('windows/runner/CMakeLists.txt');
    expect(
        RegExp(r'target_link_libraries\(\$\{BINARY_NAME\} PRIVATE[^)]*\bole32\b')
            .hasMatch(cmake),
        isTrue,
        reason: 'runner target 必须链 ole32（COM）');
    expect(
        RegExp(r'target_link_libraries\(\$\{BINARY_NAME\} PRIVATE[^)]*\bshell32\b')
            .hasMatch(cmake),
        isTrue,
        reason: 'runner target 必须链 shell32（IShellLink / SHGetKnownFolderPath）');
  });

  test('Dart syncWindowsShortcutIcons 经 setShortcutIcon 用 iconPath 下发', () {
    final String src = read('lib/src/utils/misc/shortcut_icon_sync.dart');
    expect(src.contains("MethodChannel('app.hibiki/window')"), isTrue,
        reason: '必须复用 app.hibiki/window channel');
    expect(src.contains("'setShortcutIcon'"), isTrue,
        reason: '必须调 setShortcutIcon method');
    expect(src.contains("'iconPath'"), isTrue,
        reason: 'Dart 侧入参 key 必须是 iconPath（与 native 同名）');
    // 多尺寸：必须对每个 kShortcutIcoSizes 出一帧（手写 ICO 容器，非单尺寸 encodeIco）。
    expect(src.contains('kShortcutIcoSizes'), isTrue,
        reason: '必须按 kShortcutIcoSizes 编多尺寸 .ico');
    expect(src.contains('for (final int size in kShortcutIcoSizes)'), isTrue,
        reason: '必须对每个尺寸 copyResize 一帧（多尺寸 .ico，非单尺寸）');
  });

  test('settings 页换图标成功后调 syncWindowsShortcutIcons', () {
    final String src =
        read('lib/src/pages/implementations/miscellaneous_settings_page.dart');
    expect(src.contains('syncWindowsShortcutIcons('), isTrue,
        reason: '_switchPreset / _pickCustomIcon 必须在换图标后同步 .lnk 图标');
    // 两个 Windows 触点都接：preset + custom。
    expect('syncWindowsShortcutIcons('.allMatches(src).length >= 2, isTrue,
        reason: 'preset 与 custom 两条 Windows 换图路径都须同步');
  });
}
