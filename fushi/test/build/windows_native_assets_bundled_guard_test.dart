import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2419 守卫：Windows bundle 必须带上 native assets（具体地说：`pdfium.dll`），
/// 且 PDFium 不可加载时必须**报错而不是挂死**。
///
/// 这个洞的形状值得记住，因为它绕过了本仓所有既有的绿灯：
///
/// - `fushi/windows/CMakeLists.txt` 是官方模板的重度定制副本，演进时漏掉了模板里
///   `set(NATIVE_ASSETS_DIR ...)` + `install(DIRECTORY ...)` 那两句。`linux/` 那份
///   有，Windows 这份没有。
/// - Flutter 本该自动补它的 `cmake_native_assets_migration.dart` 用
///   `replaceFirst('endforeach(bundled_library)')` 定位插入点，而 Windows 模板里
///   根本没有那个 foreach → 匹配不到 → **静默 return**，不写文件、不打日志。
/// - `sqlite3.dll` 同时由 `sqlite3_flutter_libs` 走 `PLUGIN_BUNDLED_LIBRARIES` 装进
///   bundle，于是 native-assets 这条通道从来没通过也看不出来。
/// - 后果不是「PDF 功能缺失」而是「PDF 永久挂死」：pdfrx 的 worker isolate 在
///   `execute() => sendPort.send(callback(message))` 里没有 try/catch，加载失败时
///   回包整句不执行，主 isolate 的 await 永不完成。导入对话框的 catch/finally 一条
///   都不触发，进度条永远停在原地。
///
/// 单测和 `flutter analyze` 在结构上都看不到 bundle 里有哪些文件，验证构建又跑的是
/// `--debug`（不经 install 路径）。所以这份守卫钉的是**源文件里的不变式**，是唯一
/// 能在下一次有人重写 CMakeLists 时挡住回归的东西。
///
/// 刻意钉不变式而不钉写法：只要求「有一条把 native_assets 目录装进 bundle 的
/// install 规则」「有一条 Release 缺 pdfium.dll 就失败的守卫」，变量名、换行、注释
/// 怎么改都不会误红。
void main() {
  // 测试 cwd 是 `fushi/`。
  File cmakeFile(String platform) {
    final File file = File('$platform/CMakeLists.txt');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'expected ${file.absolute.path} to exist',
    );
    return file;
  }

  /// 去掉整行注释：这两份 CMakeLists 的注释里大量出现 `pdfium.dll` /
  /// `native_assets`（本次修复自己就写了一大段），拿散文当接线会让守卫在根本没有
  /// install 规则时照样绿。
  String stripComments(String cmake) {
    return cmake
        .split('\n')
        .where((String line) => !line.trimLeft().startsWith('#'))
        .join('\n');
  }

  group('Windows bundle 必须包含 native assets', () {
    test('windows/CMakeLists.txt 把 native_assets 目录装进 bundle', () {
      final String cmake =
          stripComments(cmakeFile('windows').readAsStringSync());

      expect(
        cmake.contains('native_assets/windows'),
        isTrue,
        reason: '缺少 native assets 源目录。没有它，pdfium.dll 只会留在 '
            'build/native_assets/ 而进不了安装包，PDF 导入与 PDF 阅读器在用户机器上'
            '永久挂死（BUG-2419）。',
      );

      // install(DIRECTORY ...) 与源目录必须在同一条规则里——只 set 变量不 install
      // 等于没修。用 [\s\S] 跨行匹配，因为这条规则本来就写成三行。
      expect(
        RegExp(r'install\s*\(\s*DIRECTORY[\s\S]{0,200}NATIVE_ASSETS_DIR')
                .hasMatch(cmake) ||
            RegExp(r'install\s*\(\s*DIRECTORY[\s\S]{0,200}native_assets')
                .hasMatch(cmake),
        isTrue,
        reason: '找到了 native assets 目录，但没有 install(DIRECTORY ...) 把它装进 '
            'bundle。set 一个没人用的变量不会让 DLL 出现在 exe 旁边。',
      );
    });

    test('Profile/Release 缺 pdfium.dll 必须构建失败，而不是发一个会挂死的包', () {
      final String cmake =
          stripComments(cmakeFile('windows').readAsStringSync());

      expect(
        cmake.contains('pdfium.dll'),
        isTrue,
        reason: '缺少 pdfium.dll 的存在性守卫。补 install 规则是修复，这条守卫是防'
            '复发的另一半：没有它，下一次重写 CMakeLists 又会静默产出一个「声称支持'
            ' PDF、一导入就永久转圈」的安装包。',
      );

      // 钉「Release 缺件即 FATAL_ERROR」这个不变式，不钉具体措辞。
      final RegExp fatalOnMissing = RegExp(
        r'Profile\|Release[\s\S]{0,400}pdfium\.dll[\s\S]{0,400}FATAL_ERROR',
      );
      expect(
        fatalOnMissing.hasMatch(cmake),
        isTrue,
        reason: 'pdfium.dll 出现了，但没有「Profile/Release 缺它就 FATAL_ERROR」的'
            '守卫。与同文件里 fushi_torrent 那条 install(CODE) 守卫同款理由：禁止'
            '产出一个运行时必然不可用的发布包。',
      );
    });

    test('linux/CMakeLists.txt 同款规则仍在（防止只保留一个平台）', () {
      final String cmake = stripComments(cmakeFile('linux').readAsStringSync());
      expect(
        cmake.contains('native_assets/linux'),
        isTrue,
        reason: 'Linux 侧的 native assets install 规则不见了。Windows 的洞正是这样'
            '产生的——一份定制副本漏掉模板里的两句，然后没人发现。',
      );
    });
  });

  group('PDFium 不可加载时必须报错而不是挂死', () {
    test('PdfEngine 在 pdfrx 初始化前做可加载性断言', () {
      final File engine = File('lib/src/pdf/pdf_engine.dart');
      expect(engine.existsSync(), isTrue);
      final String source = engine.readAsStringSync();

      expect(
        source.contains('PdfiumUnavailableException'),
        isTrue,
        reason: '缺少 PDFium 不可用异常。删掉它就回到了「无声挂死」：pdfrx 的 worker '
            'isolate 吞掉同步异常，主 isolate 的 await 永不完成，导入进度条永远停在'
            '原地且无任何日志（BUG-2419）。',
      );

      // 断言必须排在 pdfrxFlutterInitialize 之前——排在后面就晚了，第一次真正的
      // PDFium 触点已经发生在 worker isolate 里。
      final int assertAt = source.indexOf('_assertPdfiumLoadable()');
      final int initAt = source.indexOf('pdfrxFlutterInitialize(');
      expect(
        assertAt,
        greaterThanOrEqualTo(0),
        reason: '找不到 _assertPdfiumLoadable 的调用点。',
      );
      expect(
        initAt,
        greaterThanOrEqualTo(0),
        reason: '找不到 pdfrxFlutterInitialize 的调用点。',
      );
      expect(
        assertAt,
        lessThan(initAt),
        reason: '可加载性断言必须排在 pdfrxFlutterInitialize 之前；排在后面时第一次'
            'PDFium 触点已经进了 worker isolate，异常又会被吞掉。',
      );
    });
  });
}
