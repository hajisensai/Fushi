import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart';

UpdateDirEntry _f(String name, DateTime modified) =>
    UpdateDirEntry(name: name, isDirectory: false, modified: modified);

UpdateDirEntry _d(String name) => UpdateDirEntry(
      name: name,
      isDirectory: true,
      modified: DateTime.fromMillisecondsSinceEpoch(0),
    );

void main() {
  group('selectStaleUpdateArtifacts (TODO-1010 纯函数：回收旧完整安装包)', () {
    final DateTime now = DateTime(2026, 6, 30, 12);
    final DateTime cutoff = now.subtract(const Duration(days: 7));
    final DateTime old = now.subtract(const Duration(days: 30));
    final DateTime fresh = now.subtract(const Duration(hours: 1));

    test('回归复现：旧完整安装包永不被回收 → 现在应被选中删除', () {
      final List<String> stale = selectStaleUpdateArtifacts(
        entries: <UpdateDirEntry>[
          _f('Hibiki-1.0.0-windows-setup.exe', old),
          _f('Hibiki-0.9.0-windows-setup.exe', old),
        ],
        cutoff: cutoff,
      );
      expect(
        stale,
        containsAll(<String>[
          'Hibiki-1.0.0-windows-setup.exe',
          'Hibiki-0.9.0-windows-setup.exe',
        ]),
      );
      expect(stale, hasLength(2));
    });

    test('新近完整包（cutoff 之后）保留——可能是上一轮刚下、待安装', () {
      final List<String> stale = selectStaleUpdateArtifacts(
        entries: <UpdateDirEntry>[
          _f('Hibiki-1.0.0-windows-setup.exe', fresh),
        ],
        cutoff: cutoff,
      );
      expect(stale, isEmpty);
    });

    test('cutoff 当刻不删（isBefore 严格小于）', () {
      final List<String> stale = selectStaleUpdateArtifacts(
        entries: <UpdateDirEntry>[
          _f('Hibiki-1.0.0-windows-setup.exe', cutoff),
        ],
        cutoff: cutoff,
      );
      expect(stale, isEmpty);
    });

    test('临时/元数据文件不在本函数职责内（由既有清理路径处理）', () {
      final List<String> stale = selectStaleUpdateArtifacts(
        entries: <UpdateDirEntry>[
          _f('Hibiki-1.0.0-windows-setup.exe.part', old),
          _f('Hibiki-1.0.0-windows-setup.exe.meta.json', old),
          _f('Hibiki-1.0.0-windows-setup.exe.owner.json', old),
        ],
        cutoff: cutoff,
      );
      expect(stale, isEmpty);
    });

    test('目录条目（含 .staging）一律跳过', () {
      final List<String> stale = selectStaleUpdateArtifacts(
        entries: <UpdateDirEntry>[
          _d('.Hibiki-1.0.0-windows-setup.exe.staging'),
          _d('some-old-dir'),
        ],
        cutoff: cutoff,
      );
      expect(stale, isEmpty);
    });

    test('排除当前活跃 asset 主文件（即便很旧也不删）', () {
      final List<String> stale = selectStaleUpdateArtifacts(
        entries: <UpdateDirEntry>[
          _f('Hibiki-1.0.0-windows-setup.exe', old),
          _f('Hibiki-0.9.0-windows-setup.exe', old),
        ],
        cutoff: cutoff,
        activeAssetFileName: 'Hibiki-1.0.0-windows-setup.exe',
      );
      expect(stale, <String>['Hibiki-0.9.0-windows-setup.exe']);
    });

    test('排除 Windows handoff 待重启安装的安装包', () {
      final List<String> stale = selectStaleUpdateArtifacts(
        entries: <UpdateDirEntry>[
          _f('Hibiki-1.0.1-windows-setup.exe', old),
          _f('Hibiki-1.0.0-windows-setup.exe', old),
        ],
        cutoff: cutoff,
        handoffInstallerFileName: 'Hibiki-1.0.1-windows-setup.exe',
      );
      expect(stale, <String>['Hibiki-1.0.0-windows-setup.exe']);
    });

    test('排除 handoff 标记 JSON 自身', () {
      final List<String> stale = selectStaleUpdateArtifacts(
        entries: <UpdateDirEntry>[
          _f('update-handoff.json', old),
          _f('Hibiki-1.0.0-windows-setup.exe', old),
        ],
        cutoff: cutoff,
      );
      expect(stale, <String>['Hibiki-1.0.0-windows-setup.exe']);
    });

    test('Android apk 与 Linux AppImage 同样被回收', () {
      final List<String> stale = selectStaleUpdateArtifacts(
        entries: <UpdateDirEntry>[
          _f('hibiki-arm64.apk', old),
          _f('Hibiki-x86_64.AppImage', old),
        ],
        cutoff: cutoff,
      );
      expect(
        stale,
        containsAll(<String>['hibiki-arm64.apk', 'Hibiki-x86_64.AppImage']),
      );
    });

    test('空目录 → 空清单（无副作用）', () {
      expect(
        selectStaleUpdateArtifacts(
          entries: const <UpdateDirEntry>[],
          cutoff: cutoff,
        ),
        isEmpty,
      );
    });
  });

  group(
      'installerToDeleteAfterSuccessfulHandoff '
      '(TODO-1089：安装成功即刻回收安装包)', () {
    const String root = r'C:\Users\wrds\AppData\Roaming\Hibiki\Hibiki\updates';
    const String installer = root + r'\Hibiki-1.0.1-windows-setup.exe';

    test('回归复现：安装成功后应立刻删掉刚装的安装包（不等 7 天 GC）', () {
      // 根因：旧逻辑安装成功只删 marker，setup.exe 只能等 7 天 GC 兜底、且 GC 只在
      // 下次检查更新时才跑；关自动检查就永不回收 → updates 堆几百 MB。安装成功即删。
      expect(
        installerToDeleteAfterSuccessfulHandoff(
          installed: true,
          installerPath: installer,
          updatesDirPath: root,
        ),
        installer,
      );
    });

    test('未成功安装（失败/未完成）不删——保留供重试与诊断', () {
      expect(
        installerToDeleteAfterSuccessfulHandoff(
          installed: false,
          installerPath: installer,
          updatesDirPath: root,
        ),
        isNull,
      );
    });

    test('installerPath 为空/为 null 不删', () {
      expect(
        installerToDeleteAfterSuccessfulHandoff(
          installed: true,
          installerPath: '',
          updatesDirPath: root,
        ),
        isNull,
      );
      expect(
        installerToDeleteAfterSuccessfulHandoff(
          installed: true,
          installerPath: null,
          updatesDirPath: root,
        ),
        isNull,
      );
    });

    test('安全约束：updates 目录之外的路径绝不删（防误删任意文件）', () {
      expect(
        installerToDeleteAfterSuccessfulHandoff(
          installed: true,
          installerPath: r'C:\Windows\System32\evil.exe',
          updatesDirPath: root,
        ),
        isNull,
      );
    });

    test('安全约束：updates 更深子目录里的文件不删（安装包只落在根）', () {
      expect(
        installerToDeleteAfterSuccessfulHandoff(
          installed: true,
          installerPath: root + r'\.staging\stray.exe',
          updatesDirPath: root,
        ),
        isNull,
      );
    });

    test('反斜杠归一：记录用正斜杠分隔、根用反斜杠分隔也判定为目录内', () {
      const String slashInstaller =
          r'C:\Users\wrds\AppData\Roaming\Hibiki\Hibiki\updates/Hibiki-1.0.1-windows-setup.exe';
      expect(
        installerToDeleteAfterSuccessfulHandoff(
          installed: true,
          installerPath: slashInstaller,
          updatesDirPath: root,
        ),
        slashInstaller,
      );
    });

    test('尾部斜杠的 updatesDirPath 不影响判定', () {
      expect(
        installerToDeleteAfterSuccessfulHandoff(
          installed: true,
          installerPath: installer,
          updatesDirPath: root + r'\',
        ),
        installer,
      );
    });

    test('updatesDirPath 为空不删（无可信根，保守）', () {
      expect(
        installerToDeleteAfterSuccessfulHandoff(
          installed: true,
          installerPath: installer,
          updatesDirPath: '',
        ),
        isNull,
      );
    });
  });
}
