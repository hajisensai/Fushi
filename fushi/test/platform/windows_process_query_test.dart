// `windows_process_query.dart` 的真实系统验证。
//
// 这层是裸 FFI：`PROCESSENTRY32W` 的字段顺序/对齐写错、`dwSize` 填错、注册表值
// 类型判断写错，**都不会抛异常**，只会安静地返回空列表或 null——而空结果在业务
// 侧与「机器上确实没有」同义，永远不会有人发现。所以这份测试的核心是**拿当前
// 进程和系统必然存在的注册表值当已知真值去对**，而不是「调用没崩就算过」。
//
// 只在 Windows 上有意义；其它平台断言「一律返回空/null」这条契约。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/desktop/windows_process_query.dart';

/// 当前进程 exe 的 basename，如 `flutter_tester.exe`。
String _ownExeName() =>
    Platform.resolvedExecutable.replaceAll('/', r'\').split(r'\').last;

/// 「（真实系统）」各组只在 Windows 上有意义，非 Windows 一律整组跳过。
///
/// 这层是裸 FFI：非 Windows 上每个入口都按契约返回空/null（「非 Windows 平台契约」
/// 那组正是断言它），于是「进程数 > 20」「注册表里必有 ProductName」这类**拿真实
/// 系统当已知真值**的断言在 Linux CI 上必然失败。作者在 Windows 本机全绿，红只在
/// CI 露头——本机 Windows 绿 ≠ CI Linux 绿。
final Object? _skipOffRealWindows =
    Platform.isWindows ? null : '真实系统断言只在 Windows 上有意义';

void main() {
  group('非 Windows 平台契约', () {
    test('全部返回空/null，调用方无需自己 gate', () {
      if (Platform.isWindows) return;
      expect(enumerateWindowsProcesses(), isEmpty);
      expect(windowsProcessImagePath(1), isNull);
      expect(windowsProcessById(1), isNull);
      expect(windowsProcessesByNames(<String>{'x.exe'}), isEmpty);
      expect(windowsProcessesByIds(<int>[1]), isEmpty);
      expect(windowsProcessesHoldingFile('/tmp/x'), isEmpty);
      expect(
        readWindowsRegistryString(
            WindowsRegistryRoot.localMachine, 'SOFTWARE', 'X'),
        isNull,
      );
      expect(
        readWindowsRegistryDword(
            WindowsRegistryRoot.localMachine, 'SOFTWARE', 'X'),
        isNull,
      );
    });
  });

  group('进程枚举（真实系统）', () {
    test('枚举到的进程数是合理量级，且必然包含当前进程', () {
      final List<WindowsProcessEntry> all = enumerateWindowsProcesses();

      // 量级哨兵：任何活着的 Windows 至少有几十个进程。扫出个位数
      // ≈ 结构体布局错了导致遍历提前中断，这正是要挡的静默失败。
      expect(
        all.length,
        greaterThan(20),
        reason: '只枚举到 ${all.length} 个进程——PROCESSENTRY32W 布局或 dwSize 可能写错了',
      );

      final Iterable<WindowsProcessEntry> self =
          all.where((WindowsProcessEntry e) => e.pid == pid);
      expect(self, hasLength(1),
          reason: '当前进程 PID $pid 必须出现在快照里（实际 ${self.length} 条）');
    });

    test('当前进程的 image 名与 resolvedExecutable 的 basename 一致', () {
      final WindowsProcessEntry? me = enumerateWindowsProcesses()
          .where((WindowsProcessEntry e) => e.pid == pid)
          .firstOrNull;
      expect(me, isNotNull);
      expect(
        me!.name.toLowerCase(),
        _ownExeName().toLowerCase(),
        reason: 'szExeFile 解码错了（定长 260 UTF-16 数组，读到 NUL 为止）',
      );
    });

    test('枚举阶段不解析路径（惰性契约——这正是比 tasklist 轻的地方）', () {
      // 全部 entry 的 path 都应为 null：枚举只读快照，不 OpenProcess 任何进程。
      final List<WindowsProcessEntry> all = enumerateWindowsProcesses();
      expect(
        all.every((WindowsProcessEntry e) => e.path == null),
        isTrue,
        reason: '枚举阶段不得解析路径，否则等于对全机每个进程 OpenProcess',
      );
    });
  }, skip: _skipOffRealWindows);

  group('路径解析（真实系统）', () {
    test('当前进程路径等于 Platform.resolvedExecutable', () {
      final String? path = windowsProcessImagePath(pid);
      expect(path, isNotNull, reason: 'QueryFullProcessImageNameW 对自己必然成功');
      expect(
        path!.toLowerCase().replaceAll('/', r'\'),
        Platform.resolvedExecutable.toLowerCase().replaceAll('/', r'\'),
      );
    });

    test('不存在的 PID 返回 null 而不是抛异常', () {
      // 0 与负数被公开 API 直接挡掉；这里用一个几乎不可能存在的高位 PID。
      expect(windowsProcessImagePath(0x7FFFFFF0), isNull);
      expect(windowsProcessImagePath(0), isNull);
      expect(windowsProcessImagePath(-1), isNull);
    });
  }, skip: _skipOffRealWindows);

  group('按名字 / 按 PID 查询（真实系统）', () {
    test('按 image 名（大小写不敏感）能查到自己，且带完整路径', () {
      final String own = _ownExeName();
      for (final String probe in <String>[
        own,
        own.toUpperCase(),
        own.toLowerCase(),
      ]) {
        final List<WindowsProcessEntry> found =
            windowsProcessesByNames(<String>{probe});
        expect(
            found.where((WindowsProcessEntry e) => e.pid == pid), hasLength(1),
            reason: '用 "$probe" 查不到当前进程');
        final WindowsProcessEntry me =
            found.firstWhere((WindowsProcessEntry e) => e.pid == pid);
        expect(me.path, isNotNull, reason: '命中项必须已解析路径');
      }
    });

    test('按 PID 批量查询：命中自己、忽略不存在的、带路径', () {
      final Map<int, WindowsProcessEntry> found =
          windowsProcessesByIds(<int>[pid, 0x7FFFFFF0, 0, -5]);
      expect(found.keys, contains(pid));
      expect(found[pid]!.path, isNotNull);
      expect(found.keys, isNot(contains(0)));
      expect(found.keys, isNot(contains(-5)));
    });

    test('windowsProcessById 返回带路径的身份', () {
      final WindowsProcessEntry? me = windowsProcessById(pid);
      expect(me, isNotNull);
      expect(me!.name.toLowerCase(), _ownExeName().toLowerCase());
      expect(me.path, isNotNull);
    });

    test('空名字集合 / 空 PID 集合返回空，不做无谓枚举', () {
      expect(windowsProcessesByNames(<String>{}), isEmpty);
      expect(windowsProcessesByIds(<int>[]), isEmpty);
    });
  }, skip: _skipOffRealWindows);

  group('文件占用者查询 / Restart Manager（真实系统）', () {
    test('当前进程必然被报为自己 exe 文件的占用者', () {
      // 这是本组的核心断言：RM_PROCESS_INFO 的字段顺序 / 定长数组尺寸写错，
      // 不会抛异常，只会读出垃圾 PID 或空列表。运行中的进程一定持有自己的
      // image 文件，是唯一不依赖环境的已知真值。
      final List<WindowsProcessEntry> holders =
          windowsProcessesHoldingFile(Platform.resolvedExecutable);
      expect(
        holders.map((WindowsProcessEntry e) => e.pid),
        contains(pid),
        reason: 'RM 没把当前进程报成自己 exe 的占用者——'
            'RM_PROCESS_INFO 布局（256/64 定长数组）可能写错了，实际拿到 $holders',
      );
    });

    test('报出的占用者带正确的 image 名与路径', () {
      final WindowsProcessEntry me =
          windowsProcessesHoldingFile(Platform.resolvedExecutable)
              .firstWhere((WindowsProcessEntry e) => e.pid == pid);
      expect(me.name.toLowerCase(), _ownExeName().toLowerCase());
      expect(
        me.path!.toLowerCase().replaceAll('/', r'\'),
        Platform.resolvedExecutable.toLowerCase().replaceAll('/', r'\'),
      );
    });

    test('无人占用的普通文件 → 空列表', () {
      final Directory tmp =
          Directory.systemTemp.createTempSync('fushi_rm_probe_');
      try {
        final File idle = File('${tmp.path}\\idle.bin')
          ..writeAsBytesSync(<int>[1, 2, 3]);
        expect(windowsProcessesHoldingFile(idle.path), isEmpty);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('不存在的文件 / 空路径 → 空列表，不抛异常', () {
      expect(
        windowsProcessesHoldingFile(r'C:\NoSuchDir\NoSuchFile.dll'),
        isEmpty,
      );
      expect(windowsProcessesHoldingFile(''), isEmpty);
    });
  }, skip: _skipOffRealWindows);

  group('注册表读取（真实系统）', () {
    const String ntCurrentVersion =
        r'SOFTWARE\Microsoft\Windows NT\CurrentVersion';

    test('读 REG_SZ：ProductName 在任何 Windows 上都存在且非空', () {
      final String? product = readWindowsRegistryString(
        WindowsRegistryRoot.localMachine,
        ntCurrentVersion,
        'ProductName',
      );
      expect(product, isNotNull, reason: 'HKLM 下 ProductName 必然存在');
      expect(product, isNotEmpty);
      expect(product!.toLowerCase(), contains('windows'));
    });

    test('读 REG_DWORD：CurrentMajorVersionNumber 是合理的版本号', () {
      final int? major = readWindowsRegistryDword(
        WindowsRegistryRoot.localMachine,
        ntCurrentVersion,
        'CurrentMajorVersionNumber',
      );
      // Win10/11 都写 10；给个宽区间，只要不是 0 或垃圾值。
      expect(major, isNotNull, reason: 'Win10+ 必然有这个值');
      expect(major, inInclusiveRange(6, 99),
          reason: '读出 $major——DWORD 解码或类型判断写错了');
    });

    test('类型不符返回 null（拿 DWORD 读法读字符串值，反之亦然）', () {
      expect(
        readWindowsRegistryDword(
          WindowsRegistryRoot.localMachine,
          ntCurrentVersion,
          'ProductName', // 实为 REG_SZ
        ),
        isNull,
      );
      expect(
        readWindowsRegistryString(
          WindowsRegistryRoot.localMachine,
          ntCurrentVersion,
          'CurrentMajorVersionNumber', // 实为 REG_DWORD
        ),
        isNull,
      );
    });

    test('不存在的键 / 值返回 null 而不是抛异常', () {
      expect(
        readWindowsRegistryString(
          WindowsRegistryRoot.localMachine,
          r'SOFTWARE\Fushi\NoSuchKey\Ever',
          'Whatever',
        ),
        isNull,
      );
      expect(
        readWindowsRegistryString(
          WindowsRegistryRoot.localMachine,
          ntCurrentVersion,
          'NoSuchValueEver',
        ),
        isNull,
      );
      expect(
        readWindowsRegistryDword(
          WindowsRegistryRoot.currentUser,
          r'Software\Fushi\NoSuchKey\Ever',
          'Whatever',
        ),
        isNull,
      );
    });

    test('HKCU 根也能读（系统代理设置就在这个根下）', () {
      // Internet Settings 键在任何有网络栈的 Windows 上都存在。
      // 值可能不存在（没开系统代理），但读键本身不该炸。
      final int? proxyEnable = readWindowsRegistryDword(
        WindowsRegistryRoot.currentUser,
        r'Software\Microsoft\Windows\CurrentVersion\Internet Settings',
        'ProxyEnable',
      );
      expect(proxyEnable, anyOf(isNull, isA<int>()));
    });
  }, skip: _skipOffRealWindows);
}
