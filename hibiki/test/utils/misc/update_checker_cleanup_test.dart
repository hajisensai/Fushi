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
      // 这是根因：历史 cleanup 只清 .part/.meta.json/.owner.json，完整 .exe/.apk
      // 从不回收，长期堆积。给两个过期完整包，期望两个都进待删清单。
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
}
