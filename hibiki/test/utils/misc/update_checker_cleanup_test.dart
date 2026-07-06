import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart';

UpdateDirEntry _f(String name, DateTime modified) =>
    UpdateDirEntry(name: name, isDirectory: false, modified: modified);

UpdateDirEntry _d(String name, [DateTime? modified]) => UpdateDirEntry(
      name: name,
      isDirectory: true,
      modified: modified ?? DateTime.fromMillisecondsSinceEpoch(0),
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

    test('回归复现：过期 .staging 暂存根按 mtime 回收（此前一律跳过 → 空根堆积）', () {
      // 根因：下载 promote 只删内层 {id} 子目录，留下空 `.<安装包名>.staging` 根；旧逻辑
      // 本函数 `if (isDirectory) continue` 跳过所有目录，空根从不被确定性回收（TODO-1149）。
      final List<String> stale = selectStaleUpdateArtifacts(
        entries: <UpdateDirEntry>[
          _d('.Hibiki-1.0.0-windows-setup.exe.staging', old),
          _d('.Hibiki-0.9.0-windows-setup.exe.staging', old),
        ],
        cutoff: cutoff,
      );
      expect(
        stale,
        containsAll(<String>[
          '.Hibiki-1.0.0-windows-setup.exe.staging',
          '.Hibiki-0.9.0-windows-setup.exe.staging',
        ]),
      );
      expect(stale, hasLength(2));
    });

    test('新近 .staging（cutoff 之后，活跃下载 root mtime 为今日）保留', () {
      final List<String> stale = selectStaleUpdateArtifacts(
        entries: <UpdateDirEntry>[
          _d('.Hibiki-1.0.0-windows-setup.exe.staging', fresh),
        ],
        cutoff: cutoff,
      );
      expect(stale, isEmpty);
    });

    test('.staging cutoff 当刻不删（isBefore 严格小于）', () {
      final List<String> stale = selectStaleUpdateArtifacts(
        entries: <UpdateDirEntry>[
          _d('.Hibiki-1.0.0-windows-setup.exe.staging', cutoff),
        ],
        cutoff: cutoff,
      );
      expect(stale, isEmpty);
    });

    test('越界守卫：非 .staging 目录一律不删（绝不误删用户数据，即便很旧）', () {
      final List<String> stale = selectStaleUpdateArtifacts(
        entries: <UpdateDirEntry>[
          _d('some-old-dir', old),
          _d('books', old),
          _d('.Hibiki-1.0.0-windows-setup.exe.staging', old),
        ],
        cutoff: cutoff,
      );
      expect(stale, <String>['.Hibiki-1.0.0-windows-setup.exe.staging']);
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

    // ---- TODO-1149：数量封顶（高频下载 7 天内也不再无界堆积）----
    final DateTime h1 = now.subtract(const Duration(hours: 1)); // 最新
    final DateTime h2 = now.subtract(const Duration(hours: 2));
    final DateTime h3 = now.subtract(const Duration(hours: 3));
    final DateTime h4 = now.subtract(const Duration(hours: 4)); // 最旧但仍 <7 天

    test('数量封顶：超出 keepNewestInstallers 的近期包也回收（默认保留最新 2 个）', () {
      // 根因：旧逻辑只按 7 天 cutoff，全部近期包永不回收 → 高频下载一直堆积。现在保留
      // 最新 N（默认 2），超出的即便仍在 7 天内也回收。
      final List<String> stale = selectStaleUpdateArtifacts(
        entries: <UpdateDirEntry>[
          _f('Hibiki-1.0.3-windows-setup.exe', h1),
          _f('Hibiki-1.0.2-windows-setup.exe', h2),
          _f('Hibiki-1.0.1-windows-setup.exe', h3),
          _f('Hibiki-1.0.0-windows-setup.exe', h4),
        ],
        cutoff: cutoff,
      );
      // 保留最新 2（h1/h2），回收较旧的两个近期包（h3/h4）。
      expect(
        stale,
        containsAll(<String>[
          'Hibiki-1.0.1-windows-setup.exe',
          'Hibiki-1.0.0-windows-setup.exe',
        ]),
      );
      expect(stale, hasLength(2));
    });

    test('keepNewestInstallers 显式=1：只保留最新 1 个近期包', () {
      final List<String> stale = selectStaleUpdateArtifacts(
        entries: <UpdateDirEntry>[
          _f('Hibiki-1.0.2-windows-setup.exe', h1),
          _f('Hibiki-1.0.1-windows-setup.exe', h2),
          _f('Hibiki-1.0.0-windows-setup.exe', h3),
        ],
        cutoff: cutoff,
        keepNewestInstallers: 1,
      );
      expect(
        stale,
        containsAll(<String>[
          'Hibiki-1.0.1-windows-setup.exe',
          'Hibiki-1.0.0-windows-setup.exe',
        ]),
      );
      expect(stale, isNot(contains('Hibiki-1.0.2-windows-setup.exe')));
      expect(stale, hasLength(2));
    });

    test('数量封顶 + 超 7 天叠加：过期的一律回收，最新名额只保留近期', () {
      final List<String> stale = selectStaleUpdateArtifacts(
        entries: <UpdateDirEntry>[
          _f('Hibiki-1.0.2-windows-setup.exe', h1),
          _f('Hibiki-1.0.1-windows-setup.exe', old), // 超 7 天
        ],
        cutoff: cutoff,
        keepNewestInstallers: 2,
      );
      // h1 在名额内且近期 → 保留；old 超 7 天 → 回收（即便在名额内）。
      expect(stale, <String>['Hibiki-1.0.1-windows-setup.exe']);
    });

    test('handoff 待装包超出保留名额也绝不回收（保护优先于数量封顶）', () {
      // handoff 是最旧那个（排名靠后），数量封顶会把它排出名额——但它正等重启安装，
      // 必须保护不删。
      final List<String> stale = selectStaleUpdateArtifacts(
        entries: <UpdateDirEntry>[
          _f('Hibiki-1.0.3-windows-setup.exe', h1),
          _f('Hibiki-1.0.2-windows-setup.exe', h2),
          _f('Hibiki-1.0.1-windows-setup.exe', h3),
          _f('Hibiki-1.0.0-windows-setup.exe', h4), // handoff 待装
        ],
        cutoff: cutoff,
        keepNewestInstallers: 1,
        handoffInstallerFileName: 'Hibiki-1.0.0-windows-setup.exe',
      );
      // 保留最新 1（h1）+ handoff（受保护）；回收中间两个（h2/h3）。
      expect(
        stale,
        containsAll(<String>[
          'Hibiki-1.0.2-windows-setup.exe',
          'Hibiki-1.0.1-windows-setup.exe',
        ]),
      );
      expect(stale, isNot(contains('Hibiki-1.0.0-windows-setup.exe')));
      expect(stale, hasLength(2));
    });

    test('.staging 数量封顶：超出 keepNewestStaging 的近期暂存根也回收（中断下载残留）', () {
      // 下载被中断留下 staging 根；高频中断在 7 天内堆一批。默认只保留最新 1 个。
      final List<String> stale = selectStaleUpdateArtifacts(
        entries: <UpdateDirEntry>[
          _d('.Hibiki-1.0.2-windows-setup.exe.staging', h1),
          _d('.Hibiki-1.0.1-windows-setup.exe.staging', h2),
          _d('.Hibiki-1.0.0-windows-setup.exe.staging', h3),
        ],
        cutoff: cutoff,
      );
      expect(
        stale,
        containsAll(<String>[
          '.Hibiki-1.0.1-windows-setup.exe.staging',
          '.Hibiki-1.0.0-windows-setup.exe.staging',
        ]),
      );
      expect(
        stale,
        isNot(contains('.Hibiki-1.0.2-windows-setup.exe.staging')),
      );
      expect(stale, hasLength(2));
    });

    test('安装包与 .staging 名额相互独立（各留各的最新 N）', () {
      final List<String> stale = selectStaleUpdateArtifacts(
        entries: <UpdateDirEntry>[
          _f('Hibiki-1.0.2-windows-setup.exe', h1),
          _f('Hibiki-1.0.1-windows-setup.exe', h2),
          _d('.Hibiki-1.0.2-windows-setup.exe.staging', h1),
          _d('.Hibiki-1.0.1-windows-setup.exe.staging', h2),
        ],
        cutoff: cutoff,
        keepNewestInstallers: 2,
        keepNewestStaging: 1,
      );
      // 安装包 keep 2 → 都保留；staging keep 1 → 回收较旧的那个。
      expect(stale, <String>['.Hibiki-1.0.1-windows-setup.exe.staging']);
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

  group(
      'stagingDirToDeleteAfterSuccessfulHandoff '
      '(TODO-1149：安装成功即刻回收 .staging 暂存根)', () {
    const String root = r'C:\Users\wrds\AppData\Roaming\Hibiki\Hibiki\updates';
    const String installer = root + r'\Hibiki-1.0.1-windows-setup.exe';
    // 期望的 staging 根由函数用 Platform.pathSeparator 重建，故 sep-aware 构造期望值，
    // 保证 Windows / Linux（CI）两种测试宿主都匹配。
    final String stagingDir =
        '$root${Platform.pathSeparator}.Hibiki-1.0.1-windows-setup.exe.staging';

    test('回归复现：安装成功后应立刻删对应 .staging 暂存根（不留空根等 GC）', () {
      // 根因：promote 只删内层 {id} 子目录，留下空 `.staging` 根；handoff 成功旧逻辑只删
      // 安装包 .exe（TODO-1089），空根靠 7 天 GC 兜底 → 每装一版残留一个空根堆积。
      expect(
        stagingDirToDeleteAfterSuccessfulHandoff(
          installed: true,
          installerPath: installer,
          updatesDirPath: root,
        ),
        stagingDir,
      );
    });

    test('未成功安装（失败/未完成）不删', () {
      expect(
        stagingDirToDeleteAfterSuccessfulHandoff(
          installed: false,
          installerPath: installer,
          updatesDirPath: root,
        ),
        isNull,
      );
    });

    test('installerPath 为空/为 null 不删', () {
      expect(
        stagingDirToDeleteAfterSuccessfulHandoff(
          installed: true,
          installerPath: '',
          updatesDirPath: root,
        ),
        isNull,
      );
      expect(
        stagingDirToDeleteAfterSuccessfulHandoff(
          installed: true,
          installerPath: null,
          updatesDirPath: root,
        ),
        isNull,
      );
    });

    test('安全约束：updates 目录之外的路径绝不删（防误删任意目录）', () {
      expect(
        stagingDirToDeleteAfterSuccessfulHandoff(
          installed: true,
          installerPath: r'C:\Windows\System32\evil.exe',
          updatesDirPath: root,
        ),
        isNull,
      );
    });

    test('安全约束：updates 更深子目录里的文件不删（安装包只落在根）', () {
      expect(
        stagingDirToDeleteAfterSuccessfulHandoff(
          installed: true,
          installerPath: root + r'\.staging\stray.exe',
          updatesDirPath: root,
        ),
        isNull,
      );
    });

    test('重建的 staging 恒为 updates 根直属且以 .staging 结尾（越界守卫）', () {
      final String? out = stagingDirToDeleteAfterSuccessfulHandoff(
        installed: true,
        installerPath: installer,
        updatesDirPath: root,
      );
      expect(out, isNotNull);
      expect(out!.endsWith('.staging'), isTrue);
      // 直属：root + 单个分隔符之后只有一个路径段（无更深子目录穿越）。
      final String rel = out.substring(root.length + 1);
      expect(rel.contains(r'\') || rel.contains('/'), isFalse);
    });

    test('尾部斜杠的 updatesDirPath 不影响判定', () {
      expect(
        stagingDirToDeleteAfterSuccessfulHandoff(
          installed: true,
          installerPath: installer,
          updatesDirPath: root + r'\',
        ),
        stagingDir,
      );
    });

    test('updatesDirPath 为空不删（无可信根，保守）', () {
      expect(
        stagingDirToDeleteAfterSuccessfulHandoff(
          installed: true,
          installerPath: installer,
          updatesDirPath: '',
        ),
        isNull,
      );
    });
  });

  group('BUG-533 接线守卫：完整包 GC 在每次 Windows 启动确定性触发', () {
    // 根因：`_cleanupOldApks` 的过期完整安装包回收（selectStaleUpdateArtifacts）此前
    // 只在 `_check`（检查更新）路径调用；用户关闭自动检查 / neverRemind 短路时它永不跑，
    // 旧安装包在 updates 目录无限堆积（用户报告「安装包没有自动清除」）。修复把兜底 GC
    // 挂到每次 Windows 启动的 `reconcilePendingWindowsInstallerHandoff` 入口。这条路径
    // 是平台耦合 static 方法（依赖 Platform.isWindows / 平台目录 / 弹窗上下文），无法在
    // 纯 Dart 单测里端到端跑，故用源码扫描守卫锚定接线，防未来重构悄悄摘掉它复发。
    late final String source;
    setUpAll(() {
      source = File(
        'lib/src/utils/misc/update_checker_release.dart',
      ).readAsStringSync();
    });

    test('reconcilePendingWindowsInstallerHandoff 内调用 _cleanupOldApks', () {
      final int reconcileIdx =
          source.indexOf('reconcilePendingWindowsInstallerHandoff(');
      expect(reconcileIdx, greaterThanOrEqualTo(0),
          reason: 'handoff reconcile 入口必须存在');
      final int nextMethodIdx =
          source.indexOf('static bool canShowDialogFromContext', reconcileIdx);
      expect(nextMethodIdx, greaterThan(reconcileIdx));
      final String body = source.substring(reconcileIdx, nextMethodIdx);
      expect(
        body.contains('await _cleanupOldApks('),
        isTrue,
        reason: 'BUG-533：兜底完整包 GC 必须在每次 Windows 启动的 reconcile 路径无条件触发，'
            '否则关闭自动检查后安装包永不清理',
      );
    });

    test(
        'TODO-1149：reconcile 内握手成功调 stagingDirToDeleteAfterSuccessfulHandoff '
        '即刻清 .staging 暂存根', () {
      final int reconcileIdx =
          source.indexOf('reconcilePendingWindowsInstallerHandoff(');
      expect(reconcileIdx, greaterThanOrEqualTo(0));
      final int nextMethodIdx =
          source.indexOf('static bool canShowDialogFromContext', reconcileIdx);
      expect(nextMethodIdx, greaterThan(reconcileIdx));
      final String body = source.substring(reconcileIdx, nextMethodIdx);
      expect(
        body.contains('stagingDirToDeleteAfterSuccessfulHandoff('),
        isTrue,
        reason: 'TODO-1149：安装成功必须连对应 `.staging` 暂存根一起立刻回收，'
            '否则每装一版残留一个空根堆积',
      );
      expect(
        body.contains('deleteStaging'),
        isTrue,
        reason: 'TODO-1149：staging 删除失败必须记 best-effort 日志（deleteStaging），'
            '由下次 GC 按 mtime 兜底',
      );
    });

    test(
        'TODO-1149：下载完成后立刻 prune（_cleanupOldApks 带 activeAssetFileName）'
        '——不等 GC / 启动 reconcile', () {
      // 根因：GC 只在检查更新 / Windows 启动 reconcile 才跑，高频下载之间旧包一直堆到
      // 下次 GC。下载完成是回收同通道旧包的最早确定时机——`_runDownloadAndInstall` 拿到
      // outFile 后必须立刻调 `_cleanupOldApks(..., activeAssetFileName: ...)`（保护刚下好
      // 的包）。源码扫描守卫锚定这条接线，防未来重构悄悄摘掉复发。
      final int idx =
          source.indexOf('static Future<void> _runDownloadAndInstall(');
      expect(idx, greaterThanOrEqualTo(0),
          reason: '_runDownloadAndInstall 必须存在');
      final int end =
          source.indexOf('reconcilePendingWindowsInstallerHandoff(', idx);
      expect(end, greaterThan(idx));
      final String body = source.substring(idx, end);
      expect(
        body.contains('_cleanupOldApks(') &&
            body.contains('activeAssetFileName:'),
        isTrue,
        reason: 'TODO-1149：下载完成后必须以刚下好的包为 active 立刻 prune 同通道旧包，'
            '否则高频下载之间旧安装包持续堆积到下次 GC',
      );
    });
  });
}
