import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-5067：flutter_logs 的 iOS 原生层用旧 API `FileHandle.seekToEndOfFile()` /
/// `write(_:)` 追加日志，设备存储写满（ENOSPC）时抛 ObjC 的
/// `NSFileHandleOperationException`，Swift 接不住，整个 app SIGABRT。补丁在
/// `ci/patches/hosted/flutter_logs-<版本>/ios/Classes/Logger.swift`，整份覆盖进 pub cache。
///
/// Swift 不在任何 Dart 测试的编译面上，所以钉住：
/// 1. 补丁目录版本 == 根 `pubspec.lock` 解析到的版本——不等时 `ci/apply-patches.sh`
///    只打一行 WARNING 就静默跳过，修复悄悄消失。
/// 2. 文件里没有任何会抛 ObjC 异常的旧 FileHandle API。
/// 3. 追加只走 `appendLine`：`do { try seekToEnd(); try write(contentsOf:); try close() }
///    catch { ... }`，两个 Output 的 `process` 都经它写；打开失败返回 nil。
/// 4. 可抛错 API 要 iOS 13.4+，`fushi/ios/Podfile` 给所有 pod 钉的部署目标不能低于它。
void main() {
  /// 测试 cwd 恒为 `fushi/`，仓库根是它的父目录。
  final Directory repoRoot = Directory.current.parent;

  String lockedVersion(String package) {
    final String lock = File(
      '${repoRoot.path}/pubspec.lock',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final RegExpMatch? m = RegExp(
      '\n  $package:\n(?:    .*\n|      .*\n)*?    version: "([^"]+)"',
    ).firstMatch(lock);
    if (m == null) throw StateError('pubspec.lock 里找不到 $package');
    return m.group(1)!;
  }

  // late：在用例里才读 lock（声明期抛错会让整个 suite 装载失败、看不出原因）。
  late final String version = lockedVersion('flutter_logs');
  late final File swift = File(
    '${repoRoot.path}/ci/patches/hosted/flutter_logs-$version/ios/Classes/Logger.swift',
  );

  /// 注释抹成空白后的源码（Swift 与 Dart 同为 C 风格注释、双引号字符串）：
  /// 注释里出现的 API 名不能冒充实现，也不能让守卫误报。
  late final String code = maskComments(
    swift.readAsStringSync().replaceAll('\r\n', '\n'),
  );

  /// 从 [signature] 起，取其后第一对配平花括号之间的函数 / 类体（不含外层括号）。
  String bodyOf(String signature, {int from = 0}) {
    final int at = code.indexOf(signature, from);
    expect(at, isNonNegative, reason: '缺 `$signature`');
    final String structural = maskCommentsAndStrings(code);
    final int open = structural.indexOf('{', at + signature.length);
    int depth = 0;
    for (int i = open; i < structural.length; i++) {
      if (structural[i] == '{') depth++;
      if (structural[i] == '}') {
        depth--;
        if (depth == 0) return code.substring(open + 1, i);
      }
    }
    throw StateError('`$signature` 的花括号不配平');
  }

  test('补丁目录版本与 pubspec.lock 一致（否则 apply-patches 静默跳过）', () {
    expect(
      swift.existsSync(),
      isTrue,
      reason:
          'flutter_logs 升到 $version 后必须把补丁移植到 '
          'ci/patches/hosted/flutter_logs-$version/',
    );
    final List<String> stale = Directory('${repoRoot.path}/ci/patches/hosted')
        .listSync()
        .whereType<Directory>()
        .map(
          (Directory d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last,
        )
        .where(
          (String name) =>
              name.startsWith('flutter_logs-') &&
              name != 'flutter_logs-$version',
        )
        .toList();
    expect(stale, isEmpty, reason: '旧版本补丁目录不会再被应用，移植后删掉');
  });

  test('没有会抛 ObjC NSFileHandleOperationException 的旧 FileHandle API', () {
    for (final String legacy in <String>[
      'seekToEndOfFile',
      'closeFile',
      'truncateFile',
      'synchronizeFile',
      'readDataToEndOfFile',
      'readData(ofLength',
      'seek(toFileOffset',
    ]) {
      expect(
        code,
        isNot(contains(legacy)),
        reason: '旧 API `$legacy` 出错时直接 abort',
      );
    }
    // `write(_ data: Data)` 旧重载；新 API 只有 `write(contentsOf:)`。
    expect(
      RegExp(r'\.write\((?!contentsOf:)').hasMatch(code),
      isFalse,
      reason: 'FileHandle.write(_:) 是旧 API，ENOSPC 时抛 ObjC 异常',
    );
    expect(code, isNot(contains('try!')), reason: 'try! 失败同样崩溃');
  });

  test('追加走 do/try seekToEnd → write(contentsOf:) → close，出错丢弃本条', () {
    final String body = bodyOf('func appendLine(');
    final int doAt = body.indexOf('do {');
    final int catchAt = body.indexOf('} catch {');
    expect(doAt, isNonNegative, reason: '写入必须包在 do 块里');
    expect(catchAt, greaterThan(doAt), reason: 'do 块必须带 catch');
    final String tryBlock = body.substring(doAt, catchAt);
    final int seek = tryBlock.indexOf('try file.seekToEnd()');
    final int write = tryBlock.indexOf('try file.write(contentsOf: data)');
    final int close = tryBlock.indexOf('try file.close()');
    expect(seek, isNonNegative);
    expect(write, greaterThan(seek), reason: '先定位到文件尾再写');
    expect(close, greaterThan(write));
    // catch 里不得再碰文件句柄（那里再抛就没人接了）。
    expect(body.substring(catchAt), isNot(contains('file.')));

    // 文件里每一处可抛错调用都必须是 `try `（不是 try? / try!，也不能漏写 try）。
    for (final String call in <String>[
      'seekToEnd()',
      'write(contentsOf:',
      'close()',
    ]) {
      for (final Match m in call.allMatches(code)) {
        final String before = code.substring(0, m.start);
        expect(
          before.endsWith('try file.'),
          isTrue,
          reason: '`$call` 必须写成 `try file.$call` 并处于 do/catch 中',
        );
      }
    }
  });

  test('FileOutput / URLOutput 的 process 都只经 appendLine 写，打开失败返回 nil', () {
    for (final String cls in <String>[
      'public class FileOutput',
      'public class URLOutput',
    ]) {
      final int clsAt = code.indexOf(cls);
      expect(clsAt, isNonNegative, reason: '缺 $cls');
      final String process = bodyOf(
        'public func process(_ string: String)',
        from: clsAt,
      );
      expect(process, contains('appendLine(string, to: file)'), reason: cls);
      expect(process, isNot(contains('.write')), reason: cls);
      expect(process, isNot(contains('seekTo')), reason: cls);
      final String open = bodyOf('func getFileHandle()', from: clsAt);
      expect(open, contains('openForAppending(atPath:'), reason: cls);
    }

    final String open = compactCode(bodyOf('func openForAppending('));
    expect(
      open,
      contains(
        'guardFileManager.default.createFile(atPath:path,contents:nil,'
        'attributes:nil)else{returnnil}',
      ),
      reason: '建文件失败（磁盘满）必须返回 nil',
    );
    expect(open, contains('returnFileHandle(forWritingAtPath:path)'));
  });

  test('fushi/ios/Podfile 给 pod 钉的部署目标 ≥ iOS 13.4（可抛错 FileHandle API 的下限）', () {
    final String podfile = File(
      '${repoRoot.path}/fushi/ios/Podfile',
    ).readAsStringSync();
    final RegExpMatch? m = RegExp(
      r"config\.build_settings\['IPHONEOS_DEPLOYMENT_TARGET'\]\s*=\s*'(\d+)\.(\d+)'",
    ).firstMatch(podfile);
    expect(m, isNotNull, reason: 'Podfile 不再覆盖 pod 部署目标时要在 podspec 层补上');
    final int major = int.parse(m!.group(1)!);
    final int minor = int.parse(m.group(2)!);
    expect(
      major > 13 || (major == 13 && minor >= 4),
      isTrue,
      reason: 'seekToEnd() / write(contentsOf:) / close() 需要 iOS 13.4+',
    );
  });
}
