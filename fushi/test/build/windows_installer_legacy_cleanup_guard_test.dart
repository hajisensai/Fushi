import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 回归守卫：Fushi 改名的「旧名残留清理」必须在 ssPostInstall 执行，
/// 不得放回 `[InstallDelete]`。
///
/// 根因（实测现场）：`[InstallDelete]` 在复制任何新文件**之前**执行，且 Inno
/// 明确不会在安装失败/取消时回滚这些删除。旧脚本把 `{app}\hibiki.exe` 等旧名
/// 二进制和旧名快捷方式放在该段，于是一次中途失败的升级把用户从「还剩个能跑的
/// 旧版」变成「一个可执行文件都没有」——用户机器上 `{app}` 里 hibiki.exe 与
/// fushi.exe 双双消失，只剩 unins000.exe，任务栏固定项成了死链接。
///
/// 修复：这些条目下沉到 `[Code]` 的 `CurStepChanged` / `ssPostInstall`
/// （新文件全部落地之后），并补上此前从未清理过的任务栏固定项。
void main() {
  String readInstallerScript() {
    final File file = File('windows/installer/fushi.iss');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'expected Inno Setup script at ${file.absolute.path}',
    );
    return file.readAsStringSync();
  }

  /// 截出 `[Section]` 头之后、下一个 `[Xxx]` 头之前的正文。
  String sectionBody(String iss, String section) {
    final int start =
        iss.indexOf(RegExp(r'^\[' + section + r'\]$', multiLine: true));
    expect(
      start,
      greaterThanOrEqualTo(0),
      reason: 'installer script must contain a [$section] section',
    );
    final String after = iss.substring(start + section.length + 2);
    final RegExpMatch? next =
        RegExp(r'^\[[A-Za-z]', multiLine: true).firstMatch(after);
    return next == null ? after : after.substring(0, next.start);
  }

  /// `[InstallDelete]` 段里真正生效的指令行（去掉空行与 `;` 注释行）。
  List<String> directiveLines(String body) => body
      .split('\n')
      .map((String line) => line.trim())
      .where((String line) => line.isNotEmpty && !line.startsWith(';'))
      .toList();

  /// `CurStepChanged` 的过程体，且**剥掉 `//` 注释**——否则把断言字面量写进
  /// 注释就能骗过守卫。
  String curStepChangedCode(String iss) {
    final RegExp proc = RegExp(
      r'procedure\s+CurStepChanged\s*\(\s*CurStep\s*:\s*TSetupStep\s*\)\s*;'
      r'(.*?)\n\s*end\s*;',
      dotAll: true,
    );
    final RegExpMatch? match = proc.firstMatch(iss);
    expect(
      match,
      isNotNull,
      reason: '必须存在 procedure CurStepChanged(CurStep: TSetupStep); '
          '旧名清理只能在它的 ssPostInstall 分支里做。',
    );
    return match!.group(1)!.split('\n').map((String line) {
      final int comment = line.indexOf('//');
      return comment < 0 ? line : line.substring(0, comment);
    }).join('\n');
  }

  test('[InstallDelete] no longer deletes legacy binaries or shortcuts', () {
    final String iss = readInstallerScript();
    final List<String> lines =
        directiveLines(sectionBody(iss, 'InstallDelete'));

    expect(
      lines,
      isNotEmpty,
      reason: '[InstallDelete] 至少还要保留 galgame_helper 那条',
    );
    for (final String line in lines) {
      expect(
        line.toLowerCase().contains('hibiki'),
        isFalse,
        reason: '[InstallDelete] 在复制新文件前执行且不可回滚：任何旧名二进制/'
            '快捷方式的删除都必须挪到 ssPostInstall，否则一次失败的升级会让用户'
            '连一个可执行文件都不剩。命中行：$line',
      );
    }
    expect(
      lines.any((String line) => line.contains(r'{app}\galgame_helper')),
      isTrue,
      reason: 'galgame_helper 归属 [InstallDelete]（新包同样往 {app} 写 helper '
          '组件，必须复制前删；且它不是可执行入口，删早了不影响可运行性）',
    );
  });

  test('ssPostInstall removes the legacy binaries after files land', () {
    final String code = curStepChangedCode(readInstallerScript());

    expect(
      code.contains('if CurStep <> ssPostInstall then'),
      isTrue,
      reason: '清理必须门在 ssPostInstall（新文件已全部落地）之后',
    );
    const List<String> legacyBinaries = <String>[
      r"DeleteFile(ExpandConstant('{app}\hibiki.exe'));",
      r"DeleteFile(ExpandConstant('{app}\hibiki_update_launcher.exe'));",
      r"DeleteFile(ExpandConstant('{app}\hibiki_torrent_ffi.dll'));",
      r"DeleteFile(ExpandConstant('{app}\hoshidicts_ffi.dll'));",
    ];
    for (final String call in legacyBinaries) {
      expect(
        code.contains(call),
        isTrue,
        reason: 'ssPostInstall 必须清掉旧名二进制，缺失：$call',
      );
    }
  });

  test('ssPostInstall covers all three legacy shortcut locations', () {
    final String code = curStepChangedCode(readInstallerScript());

    const Map<String, String> shortcuts = <String, String>{
      '桌面': r"DeleteFile(ExpandConstant('{userdesktop}\Hibiki.lnk'));",
      '开始菜单程序组': r"DeleteFile(ExpandConstant('{group}\Hibiki.lnk'));",
      // Windows 不提供程序化「固定到任务栏」的接口，所以只能删死链接、
      // 无法自动重新固定；但**不删**就是用户点任务栏图标毫无反应。
      '任务栏固定项': r"DeleteFile(ExpandConstant('{userappdata}\Microsoft"
          r"\Internet Explorer\Quick Launch\User Pinned\TaskBar\Hibiki.lnk'));",
    };
    shortcuts.forEach((String where, String call) {
      expect(
        code.contains(call),
        isTrue,
        reason: '旧名快捷方式三处位置必须都在 ssPostInstall 清理，缺「$where」：'
            '$call',
      );
    });
  });

  test('start menu group is forced back to Fushi and the legacy one cleaned',
      () {
    final String iss = readInstallerScript();

    expect(
      RegExp(r'^UsePreviousGroup=no\s*$', multiLine: true).hasMatch(iss),
      isTrue,
      reason: 'Inno 默认 UsePreviousGroup=yes 会从卸载键读回旧组名 Hibiki，'
          '使 {group} 指向 ...\\Programs\\Hibiki，新建的 Fushi 快捷方式落进一个'
          '叫 Hibiki 的文件夹。必须显式 UsePreviousGroup=no。',
    );

    final String code = curStepChangedCode(iss);
    const List<String> legacyGroup = <String>[
      r"DeleteFile(ExpandConstant('{userprograms}\Hibiki\Hibiki.lnk'));",
      r"DeleteFile(ExpandConstant('{userprograms}\Hibiki\Fushi.lnk'));",
      r"RemoveDir(ExpandConstant('{userprograms}\Hibiki'));",
    ];
    for (final String call in legacyGroup) {
      expect(
        code.contains(call),
        isTrue,
        reason: '遗留的 Programs\\Hibiki 程序组必须清空后移除，缺失：$call',
      );
    }
  });
}
