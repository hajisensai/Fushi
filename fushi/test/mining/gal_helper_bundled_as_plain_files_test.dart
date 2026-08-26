import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_helper_installer.dart';

/// BUG-1449：helper 改为**构建期**解压成普通文件随包，消灭「需要与本体保持同步的第二份副本」。
///
/// 旧模型（helper 走网络下载时的设计）是：随包发 zip + sha256 侧车 → 运行期校验、解压、
/// 换入 `voice_hook/<arch>/`。改成随包内置后（BUG-1196）这套机制的前提没了，却留下一个
/// 必须与本体保持同步的解压副本——而「保持同步」正是 BUG-1448 断掉的环节：已装组件停在
/// 五天前的版本，注入后建出旧契约共享内存段，本体报 `protocol_mismatch`。
///
/// 新模型：`install_into_bundle.ps1` 在构建期把两个架构都解压进产物的
/// `voice_hook/<arch>/`，`hibiki.iss` 的 `Source: {#SourceDir}\*` 递归把它带进安装包。
/// helper 与本体同一次构建产出、同一个安装包落地，漂移在结构上不再可能。
///
/// 本文件钉住这条链路上三个「一改就回归」的点。
/// 等到 [image] 真的被当成映像加载：Windows 对已加载映像拒绝写打开，这比「等固定时长」
/// 或「等子进程输出」都确定——判据就是占用本身。
Future<void> _waitUntilLoadedAsImage(File image) async {
  for (int i = 0; i < 100; i++) {
    try {
      image.openSync(mode: FileMode.append).closeSync();
    } on FileSystemException {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('占位进程始终没有锁住 ${image.path}');
}

void main() {
  final File script = File(
    '../native/galgame_hook/tools/install_into_bundle.ps1',
  );
  final File buildScript = File(
    '../native/galgame_hook/tools/build_distribution.ps1',
  );
  final File fingerprintScript = File(
    '../native/galgame_hook/tools/helper_source_fingerprint.ps1',
  );
  final File windowsCmake = File('windows/CMakeLists.txt');
  final File iss = File('windows/installer/fushi.iss');
  final List<File> workflows = <File>[
    File('../.github/workflows/release-desktop.yml'),
    File('../.github/workflows/build-multiplatform.yml'),
  ];

  setUpAll(() {
    for (final File f in <File>[
      script,
      buildScript,
      fingerprintScript,
      windowsCmake,
      iss,
      ...workflows,
    ]) {
      expect(f.existsSync(), isTrue, reason: '守卫锚点文件不存在：${f.path}');
    }
  });

  group('构建期解压脚本与 Dart 清单不得漂移 (BUG-1449)', () {
    // 两份清单是不得已（一份给 PowerShell、一份给 Dart），但「两份各自漂移」正是
    // BUG-1345 的形态。这里逐架构逐条比对，任一侧增删都判红。
    for (final String arch in <String>['x86', 'x64']) {
      test('$arch 必需文件清单与 galgameHelperRequiredFiles 逐条一致', () {
        final String src = script.readAsStringSync();
        final int start = src.indexOf("'$arch' = @(");
        expect(
          start,
          greaterThanOrEqualTo(0),
          reason: '脚本里找不到 $arch 的清单块，守卫锚点失效',
        );
        final int end = src.indexOf(')', start);
        expect(end, greaterThan(start));
        final String block = src.substring(start, end);

        final List<String> fromScript = RegExp(
          r"'([^']+\.[A-Za-z0-9]+)'",
        ).allMatches(block).map((RegExpMatch m) => m.group(1)!).toList();
        // classdata.tpk / COPYING 之类没有常规扩展名的条目也要覆盖到，
        // 用「引号内不含空格且不是 arch 名」再兜一遍，避免正则漏项导致假绿。
        final List<String> allQuoted = RegExp(r"'([^']+)'")
            .allMatches(block)
            .map((RegExpMatch m) => m.group(1)!)
            .where((String v) => v != arch)
            .toList();

        expect(
          allQuoted..sort(),
          equals(galgameHelperRequiredFiles(arch).toList()..sort()),
          reason:
              'install_into_bundle.ps1 的 $arch 清单与 Dart 侧不一致：'
              '构建期校验会漏检或误报，用户装到残缺 helper 才发现',
        );
        // 交叉确认上面的宽松正则确实覆盖了带扩展名的那批（防两个正则一起写错）。
        expect(allQuoted.toSet().containsAll(fromScript), isTrue);
      });
    }
  });

  group('两个 workflow 都走构建期解压，不再随包发 zip (BUG-1449)', () {
    for (final File wf in workflows) {
      test('${wf.path.split('/').last} 调用共用脚本且不复制 zip 到 galgame_helper', () {
        final String src = wf.readAsStringSync();
        expect(
          src.contains('install_into_bundle.ps1'),
          isTrue,
          reason: '${wf.path} 不再调用构建期解压脚本，helper 不会进包',
        );
        // 旧形态的唯一指纹：把 voice_hook_*.zip 复制进 galgame_helper 目录。
        expect(
          RegExp(r"galgame_helper'").hasMatch(src),
          isFalse,
          reason:
              '${wf.path} 又在随包发 zip 归档：'
              '磁盘上重新出现「需要与本体同步的第二份副本」，正是 BUG-1449 要消灭的形态',
        );
      });
    }
  });

  test('本地 Windows 构建同样走普通文件安装且无新 dist 时清旧 helper (BUG-1881)', () {
    final String src = windowsCmake.readAsStringSync();
    final int start = src.indexOf('# === galgame hook helper 随包普通文件');
    final int end = src.indexOf('# === Magpie', start);
    expect(
      start,
      greaterThanOrEqualTo(0),
      reason: '找不到 galgame helper CMake 段',
    );
    expect(end, greaterThan(start), reason: '找不到 galgame helper CMake 段结束');
    final String block = src.substring(start, end);

    expect(block, contains('install_into_bundle.ps1'));
    expect(block, contains('-AllowMissingDistribution'));
    expect(
      block,
      isNot(contains('install(FILES')),
      reason: '本地构建又只复制 zip：增量 bundle 会继续保留旧 voice_hook plain files',
    );

    final String installer = script.readAsStringSync();
    expect(
      installer,
      contains("Join-Path \$BundleDirectory 'galgame_helper'"),
      reason: '旧 zip 目录不清理时仍可在运行期把旧 helper 回填回来',
    );
    expect(
      installer,
      contains("Join-Path \$BundleDirectory 'voice_hook'"),
      reason: '可选 dist 缺失时必须清掉增量 bundle 里的旧 helper',
    );
    expect(installer, contains('if (-not \$AllowMissingDistribution)'));
  });

  /// BUG-1880 ①：「dist 齐全但指纹属于别的 checkout」这档宽容必须按构建配置门控。
  ///
  /// 写死 `-AllowStaleDistribution` 等于让 Profile/Release 也能拿另一份源码的 helper
  /// 凑发布产物。Flutter 的 VS 生成器是多配置的（configure 期 CMAKE_BUILD_TYPE 为空），
  /// 所以判断只能是 generator expression，不能在 configure 期算好再写死。
  test('陈旧 dist 的宽容按配置门控，只有 Debug 拿得到 (BUG-1880)', () {
    final String src = windowsCmake.readAsStringSync();
    final int start = src.indexOf('# === galgame hook helper 随包普通文件');
    final int end = src.indexOf('# === Magpie', start);
    // 注释里也会写到这个开关名，断言只看真正传参的那几行。
    final String code = src
        .substring(start, end)
        .split('\n')
        .where((String line) => !line.trimLeft().startsWith('#'))
        .join('\n');

    expect(
      code,
      contains(r'$<$<CONFIG:Debug>:-AllowStaleDistribution>'),
      reason: '陈旧 dist 的宽容没按配置门控：Release 也会静默接受别的 checkout 的 helper',
    );
    expect(
      RegExp(r'-AllowStaleDistribution').allMatches(code).length,
      1,
      reason: '除 genex 之外还有第二处传 -AllowStaleDistribution，门控被绕过',
    );
    expect(
      script.readAsStringSync(),
      contains('if (-not \$AllowStaleDistribution)'),
      reason: '脚本侧不再区分「dist 缺失」与「dist 属于别的 checkout」，配置门控就失效了',
    );
  });

  /// BUG-1880 ②：清理陈旧 helper 不得用「删不掉就抛」的 `Remove-Item -Recurse`。
  ///
  /// voice_hook\<arch>\ 里正是被注进游戏、由宿主持有到宿主退出的那几个文件，开发机上
  /// 「上次玩的游戏还没退」是常态。删除会被 Windows 拒绝 → 脚本退非 0 → CMake
  /// install(CODE) 的 FATAL_ERROR → 整个 flutter build windows 因无关原因失败。
  test('陈旧 helper 一律走 Disable-FushiStaleHelper 让位，不直接删 (BUG-1880)', () {
    final String installer = script.readAsStringSync();
    expect(
      installer,
      contains('[IO.Directory]::Move'),
      reason: '被映射的 hook DLL 删不掉但可以改名；不改名就只剩「炸掉构建」或「留着旧件」',
    );
    // 三个清理点（legacy 归档目录 / voice_hook 根 / voice_hook\<arch>）必须同一条路径。
    expect(
      RegExp(r'Disable-FushiStaleHelper -Path').allMatches(installer).length,
      4,
      reason: '有清理点绕过了 Disable-FushiStaleHelper（被占用时会直接炸掉构建）',
    );
    for (final String stillDeleted in <String>[
      r'Remove-Item -LiteralPath $legacyBundle',
      r'Remove-Item -LiteralPath $plainBundle',
      r'Remove-Item -LiteralPath $target',
    ]) {
      expect(
        installer,
        isNot(contains(stillDeleted)),
        reason: '$stillDeleted 又回到就地删除：被占用时整个构建会失败',
      );
    }
  });

  test('可选 dist 缺失时真实脚本会删除两份陈旧 helper (BUG-1881)', () async {
    if (!Platform.isWindows) return;

    final Directory temp = Directory.systemTemp.createTempSync(
      'fushi_helper_optional_dist_',
    );
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final Directory bundle = Directory('${temp.path}/bundle')..createSync();
    final Directory legacy = Directory('${bundle.path}/galgame_helper')
      ..createSync();
    final Directory plain = Directory('${bundle.path}/voice_hook/x64')
      ..createSync(recursive: true);
    File('${legacy.path}/voice_hook_x64.zip').writeAsStringSync('stale');
    File('${plain.path}/fushi_voice_hook.dll').writeAsStringSync('stale');

    final ProcessResult result = await Process.run('powershell.exe', <String>[
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.absolute.path,
      '-BundleDirectory',
      bundle.path,
      '-DistDirectory',
      '${temp.path}/missing-dist',
      '-AllowMissingDistribution',
    ]);

    expect(
      result.exitCode,
      0,
      reason: 'stdout=${result.stdout}\nstderr=${result.stderr}',
    );
    expect(legacy.existsSync(), isFalse);
    expect(Directory('${bundle.path}/voice_hook').existsSync(), isFalse);
  });

  test('完整但源码指纹陈旧的 dist 也不能回填旧 helper (BUG-1881)', () async {
    if (!Platform.isWindows) return;

    final Directory temp = Directory.systemTemp.createTempSync(
      'fushi_helper_stale_dist_',
    );
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final Directory bundle = Directory('${temp.path}/bundle')..createSync();
    final Directory plain = Directory('${bundle.path}/voice_hook/x64')
      ..createSync(recursive: true);
    File('${plain.path}/fushi_voice_hook.dll').writeAsStringSync('stale');
    final Directory dist = Directory('${temp.path}/dist')..createSync();
    for (final String arch in <String>['x86', 'x64']) {
      File('${dist.path}/voice_hook_$arch.zip').writeAsBytesSync(<int>[]);
      File(
        '${dist.path}/voice_hook_$arch.zip.sha256',
      ).writeAsStringSync('0' * 64);
    }
    File('${dist.path}/voice_hook_source.sha256').writeAsStringSync('0' * 64);

    // Profile/Release 只拿到 -AllowMissingDistribution：指纹属于别的 checkout 时必须
    // 硬失败，而不是悄悄禁用 helper 继续产出一个「本体新、helper 来自另一份源码」的包。
    final ProcessResult strict = await Process.run('powershell.exe', <String>[
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.absolute.path,
      '-BundleDirectory',
      bundle.path,
      '-DistDirectory',
      dist.path,
      '-AllowMissingDistribution',
    ]);
    expect(
      strict.exitCode,
      isNot(0),
      reason: '陈旧 dist 在没有 -AllowStaleDistribution 时必须失败',
    );
    expect('${strict.stderr}', contains('distribution is stale'));

    // Debug 额外拿到 -AllowStaleDistribution：继续构建，但旧 helper 必须明确不可用。
    final ProcessResult result = await Process.run('powershell.exe', <String>[
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.absolute.path,
      '-BundleDirectory',
      bundle.path,
      '-DistDirectory',
      dist.path,
      '-AllowMissingDistribution',
      '-AllowStaleDistribution',
    ]);

    expect(
      result.exitCode,
      0,
      reason: 'stdout=${result.stdout}\nstderr=${result.stderr}',
    );
    expect(Directory('${bundle.path}/voice_hook').existsSync(), isFalse);
  });

  /// BUG-1880：被占用的 helper 不得让整个 `flutter build windows` 失败，但也不得留在
  /// 运行期真正读的那条路径上。
  ///
  /// 运行期判据（`GalgameHookRuntimeStage._ensureStaged`）是按精确路径查
  /// `voice_hook/<arch>/fushi_voice_injector.exe` 等文件，一个不在原位就判该架构不可用。
  /// 所以「整目录改名让位」就是运行期读得懂的「明确不可用」——被映射的映像文件删不掉，
  /// 但可以改名（本用例用一个真的在跑的 exe 复现这条占用）。
  test('helper 正在被进程占用时：构建不中断，但旧 helper 必须离开运行期路径 (BUG-1880)', () async {
    if (!Platform.isWindows) return;

    final Directory temp = Directory.systemTemp.createTempSync(
      'fushi_helper_locked_',
    );
    final Directory bundle = Directory('${temp.path}/bundle')..createSync();
    final Directory plain = Directory('${bundle.path}/voice_hook/x64')
      ..createSync(recursive: true);
    final File injector = File('${plain.path}/fushi_voice_injector.exe');
    // ping.exe 只是「一个能长期运行的真 exe」：文件名才是运行期判据。
    File('${Platform.environment['WINDIR']}\\System32\\ping.exe').copySync(
      injector.path,
    );

    final Process holder = await Process.start(injector.path, <String>[
      '-n',
      '30',
      '127.0.0.1',
    ]);
    // 先登记回收，再等占用成立：等待本身可能超时抛出，那时占位进程也必须被杀掉。
    addTearDown(() {
      holder.kill();
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      } on FileSystemException {
        // 宿主刚被杀、句柄尚未释放：临时目录留给系统清理，不是被测行为。
      }
    });
    // 等到写打开被拒——那才说明映像已经加载、占用条件成立。不看 stdout：ping 的
    // CRT 在非控制台下是全缓冲的，第一行要等几十秒才出来。
    await _waitUntilLoadedAsImage(injector);

    final ProcessResult result = await Process.run('powershell.exe', <String>[
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.absolute.path,
      '-BundleDirectory',
      bundle.path,
      '-DistDirectory',
      '${temp.path}/missing-dist',
      '-AllowMissingDistribution',
    ]);

    expect(
      result.exitCode,
      0,
      reason:
          '被占用的 helper 让构建整体失败了（这正是 BUG-1880）：'
          'stdout=${result.stdout}\nstderr=${result.stderr}',
    );
    expect(
      injector.existsSync(),
      isFalse,
      reason: '旧 injector 还在运行期查找的那条路径上，app 会继续把它注进游戏',
    );
    expect(
      Directory('${bundle.path}/voice_hook').existsSync(),
      isFalse,
      reason: '运行期按 voice_hook/<arch>/ 定位，这个路径必须消失',
    );
    expect(
      bundle
          .listSync()
          .whereType<Directory>()
          .map((Directory d) => d.path.split(Platform.pathSeparator).last)
          .any((String name) => name.startsWith('voice_hook.stale')),
      isTrue,
      reason: '让位后的目录不见了：说明走的是删除路径，占用时会退非 0',
    );
  });

  /// BUG-1880：删不掉又改不掉名（例如杀软/索引器以普通句柄打开）时没有任何办法让旧件
  /// 失效，只能硬失败——但错误必须自解释，而不是一句 Access denied。
  test('既删不掉又让不了位时硬失败，且错误信息自解释 (BUG-1880)', () async {
    if (!Platform.isWindows) return;

    final Directory temp = Directory.systemTemp.createTempSync(
      'fushi_helper_pinned_',
    );
    final Directory bundle = Directory('${temp.path}/bundle')..createSync();
    final Directory plain = Directory('${bundle.path}/voice_hook/x64')
      ..createSync(recursive: true);
    final File dll = File('${plain.path}/fushi_voice_hook.dll')
      ..writeAsStringSync('stale');
    // Dart 的文件句柄不共享 DELETE，Windows 因此同时拒绝删除与目录改名。
    final RandomAccessFile pinned = dll.openSync(mode: FileMode.append);
    addTearDown(() {
      pinned.closeSync();
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    final ProcessResult result = await Process.run('powershell.exe', <String>[
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.absolute.path,
      '-BundleDirectory',
      bundle.path,
      '-DistDirectory',
      '${temp.path}/missing-dist',
      '-AllowMissingDistribution',
    ]);

    expect(
      result.exitCode,
      isNot(0),
      reason: '让不掉位却继续构建 = 旧 helper 原样留在运行期路径上（BUG-1881 复发）',
    );
    final String stderr = '${result.stderr}';
    expect(stderr, contains('Cannot disable the stale galgame helper'));
    expect(
      stderr,
      contains('voice_hook'),
      reason: '错误必须指出是哪个目录，否则用户无从知道该关掉什么',
    );
    expect(
      stderr,
      contains('fushi_voice_injector.exe'),
      reason: '错误必须提示先退出游戏 / helper 进程',
    );
    expect(
      dll.existsSync(),
      isTrue,
      reason: '硬失败时不得留下半删状态',
    );
  });

  test('组包与安装必须共享当前源码指纹契约 (BUG-1881)', () {
    final String build = buildScript.readAsStringSync();
    final String install = script.readAsStringSync();
    for (final String source in <String>[build, install]) {
      expect(source, contains('helper_source_fingerprint.ps1'));
      expect(source, contains('Get-FushiHelperSourceFingerprint'));
      expect(source, contains('voice_hook_source.sha256'));
    }
  });

  test('安装器必须清掉上一版残留的随包归档 (BUG-1449)', () {
    final String src = iss.readAsStringSync();
    expect(
      src.contains('[InstallDelete]'),
      isTrue,
      reason: 'hibiki.iss 没有 [InstallDelete] 段',
    );
    final int start = src.indexOf('[InstallDelete]');
    final int end = src.indexOf('[Files]', start);
    expect(end, greaterThan(start), reason: '[InstallDelete] 之后应有 [Files]');
    expect(
      src.substring(start, end).contains(r'{app}\galgame_helper'),
      isTrue,
      reason:
          '升级时不清掉旧 galgame_helper：用户一旦删过 installed.sha256，'
          '旧 zip 会把安装器刚放好的新组件回填成旧的，直接复发 BUG-1448',
    );
  });
}
