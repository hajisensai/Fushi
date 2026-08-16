import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/net/app_user_agent.dart';

import '../helpers/source_guard.dart';

/// 对外 User-Agent 守卫：app **以自己的身份**发出去的 UA 不得再报旧名。
///
/// 改名之后 UA 字面量散落在各调用方各写各的，实测残留了 4 处 `Hibiki`
/// （OpenSubtitles 客户端与其设置页默认值、着色器下载器 ×2、自定义字体下载）。
/// 对外部服务来说 UA 就是这个 app 的身份，两个名字同时在跑 = 同一个客户端有两个
/// 身份。定向测试按功能域挑文件，结构上挑不到「哪个文件里还剩一条 UA 字面量」，
/// 所以这里按目录全树扫。
///
/// 白名单里的是**故意伪装成浏览器**的场景（不是「报自己」）：Aidoku 源站要浏览器
/// UA 才不被 WAF 拦、Google Lens OCR 要求 Chromium UA、YouTube 分离流的回放 UA
/// 必须与铸造 URL 时逐字一致。它们不受本守卫约束。
void main() {
  /// 允许出现浏览器伪装 UA 的文件（相对 `fushi/`）。
  const Set<String> browserImpersonationFiles = <String>{
    'lib/src/media/manga/aidoku/aidoku_reader_chapter.dart',
    'lib/src/media/manga/aidoku/aidoku_source_browse_page.dart',
    'lib/src/media/manga/ocr/google_lens_ocr_service.dart',
    'lib/src/media/video/youtube_source_resolver.dart',
  };

  /// 旧名在**非 UA 语境**下的合法残留（迁移入口、旧包名、旧资产契约）不在扫描面
  /// 内——本守卫只看带 `User-Agent` / `userAgent` 的那一行。
  /// 收尾引号必须吃掉：真实写法是 `'User-Agent': '...'`（map 字面量），
  /// `User-Agent` 与冒号之间隔着一个引号。漏掉它守卫就永远绿——这条正则是被
  /// 变异实测（把一条 UA 改回 Hibiki，守卫仍绿）逼出来的。
  final RegExp userAgentLine = RegExp(
    r'''(User-Agent|userAgent)['"]?\s*[:=]''',
    caseSensitive: true,
  );
  final RegExp legacyName = RegExp('Hibiki', caseSensitive: false);

  test('对外 UA 不得再报旧名 Hibiki', () {
    final Directory lib = Directory('lib');
    expect(lib.existsSync(), isTrue, reason: '必须在 fushi/ 下跑');

    final List<String> offenders = <String>[];
    for (final FileSystemEntity entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String relative = entity.path.replaceAll(r'\', '/');
      final String key = relative.substring(relative.indexOf('lib/'));
      if (browserImpersonationFiles.contains(key)) continue;
      // 注释讲的是历史，不是发出去的字节：走共享原语等长掩码（字符串字面量原样
      // 保留，故 UA 本体不受影响；行号与原文一致，取证仍回原行切片）。手写
      // startsWith 只跳整行注释，会放过块注释与行尾注释——source_guard_adoption
      // 那条守卫就是为此立的。
      final List<String> raw = entity.readAsLinesSync();
      final List<String> masked = maskComments(raw.join('\n')).split('\n');
      for (int i = 0; i < masked.length && i < raw.length; i++) {
        final String line = masked[i];
        if (!userAgentLine.hasMatch(line)) continue;
        if (!legacyName.hasMatch(line)) continue;
        offenders.add('$key:${i + 1}: ${raw[i].trim()}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '这些行仍以旧名 Hibiki 对外报身份，改用 fushiUserAgent(<组件名>)：\n'
          '${offenders.join('\n')}',
    );
  });

  test('fushiUserAgent 形状稳定（对外身份不能随手改）', () {
    expect(
      fushiUserAgent('shader-downloader'),
      'fushi/shader-downloader (https://github.com/hajisensai/fushi)',
    );
    expect(fushiUserAgent('  custom-fonts  '), contains('fushi/custom-fonts '));
  });
}
