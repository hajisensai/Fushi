// 命名统一轮 G8 + BUG-1122：单一 MIME 映射表守卫。
//
// 6 份「扩展名 → MIME」switch 副本收敛到 hibiki_core `kMimeTypeByExtension`：
// sync server `_guessContentType` / 云上传 `guessSyncContentType` / EPUB
// `fallbackMimeType` / 词典媒体 `dictionaryMediaMimeType` / 桌面查词浮窗
// `_globalLookupImageMime` 直接查表；hibiki_anki 无 hibiki_core 依赖（独立模块），
// 其 `mimeTypeForPath` 持逐项镜像 `kAnkiMimeTypeByExtension`。
//
// 本文件：
// ① BUG-1122 回归——`.webp` 在所有入口都必须推成 image/webp（旧 sync server 副本
//   缺 webp → 封面按 application/octet-stream 下发，对端 WebView 拒绝内联渲染）；
//   server HTTP 层回归见 hibiki_sync_server_books_test.dart。
// ② 各历史分歧扩展名断言（旧副本间覆盖面差集：aac/wav 只在 anki、字幕/视频只在
//   server、css/js/字体只在 EPUB……并集后处处一致）。
// ③ anki 镜像逐项一致守卫——改任一侧表必须同步另一侧。
// ④ 源码扫描守卫——lib 下不得再新增「扩展名→image MIME」的 switch 副本。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/dictionary/dictionary_media_types.dart'
    show dictionaryMediaMimeType;
import 'package:hibiki/src/epub/epub_book.dart' show fallbackMimeType;
import 'package:hibiki/src/sync/sync_utils.dart' show guessSyncContentType;
import 'package:hibiki_anki/hibiki_anki.dart'
    show kAnkiMimeTypeByExtension, mimeTypeForPath;
import 'package:hibiki_core/hibiki_core.dart'
    show kFallbackMimeType, kMimeTypeByExtension, mimeTypeForFilePath;

/// 从当前 cwd 向上找含 docs/BUGS.md 的仓库根（与 bugs_per_file_guard_test 同法）。
Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/docs/BUGS.md').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('找不到含 docs/BUGS.md 的仓库根（从 ${Directory.current.path} 向上）');
}

void main() {
  group('BUG-1122：webp 在所有 MIME 入口推成 image/webp', () {
    test('共享表 mimeTypeForFilePath', () {
      expect(mimeTypeForFilePath('cover.webp'), 'image/webp');
      expect(mimeTypeForFilePath('/covers/a b/cover.webp'), 'image/webp');
      expect(mimeTypeForFilePath(r'C:\covers\cover.WEBP'), 'image/webp');
    });

    test('sync 上传 guessSyncContentType（旧副本缺 webp）', () {
      expect(guessSyncContentType('cover.webp'), 'image/webp');
    });

    test('EPUB fallbackMimeType（旧副本缺 webp）', () {
      expect(fallbackMimeType('images/illust.webp'), 'image/webp');
    });

    test('词典媒体 dictionaryMediaMimeType', () {
      expect(dictionaryMediaMimeType('gaiji/x.webp'), 'image/webp');
    });

    test('hibiki_anki mimeTypeForPath（镜像表）', () {
      expect(mimeTypeForPath('clip.webp'), 'image/webp');
    });
  });

  group('历史分歧扩展名（旧 6 份副本覆盖面差集，并集后处处一致）', () {
    test('音频：aac/wav 旧只在 anki 副本，其余处曾回退 octet-stream', () {
      expect(mimeTypeForFilePath('a.aac'), 'audio/aac');
      expect(mimeTypeForFilePath('a.wav'), 'audio/wav');
      expect(guessSyncContentType('a.aac'), 'audio/aac');
      expect(fallbackMimeType('a.wav'), 'audio/wav');
    });

    test('视频/字幕：旧只在 sync server 副本', () {
      expect(mimeTypeForFilePath('a.mp4'), 'video/mp4');
      expect(mimeTypeForFilePath('a.mkv'), 'video/x-matroska');
      expect(mimeTypeForFilePath('a.webm'), 'video/webm');
      expect(mimeTypeForFilePath('a.ts'), 'video/mp2t');
      expect(mimeTypeForFilePath('a.srt'), 'text/plain; charset=utf-8');
      expect(mimeTypeForFilePath('a.ass'), 'text/plain; charset=utf-8');
      expect(mimeTypeForFilePath('a.ssa'), 'text/plain; charset=utf-8');
      expect(mimeTypeForFilePath('a.vtt'), 'text/vtt; charset=utf-8');
      expect(mimeTypeForPath('a.mkv'), 'video/x-matroska');
    });

    test('文档/字体：css/js/xhtml/字体旧只在 EPUB 副本', () {
      expect(mimeTypeForFilePath('a.css'), 'text/css');
      expect(mimeTypeForFilePath('a.js'), 'application/javascript');
      expect(mimeTypeForFilePath('a.xhtml'), 'text/html');
      expect(mimeTypeForFilePath('a.woff2'), 'font/woff2');
      expect(mimeTypeForFilePath('a.otf'), 'font/otf');
      expect(guessSyncContentType('a.css'), 'text/css');
    });

    test('epub/json/常见音频：与旧 sync 副本一致', () {
      expect(mimeTypeForFilePath('a.epub'), 'application/epub+zip');
      expect(mimeTypeForFilePath('a.json'), 'application/json');
      expect(mimeTypeForFilePath('a.mp3'), 'audio/mpeg');
      expect(mimeTypeForFilePath('a.m4b'), 'audio/mp4');
      expect(mimeTypeForFilePath('a.m4a'), 'audio/mp4');
      expect(mimeTypeForFilePath('a.ogg'), 'audio/ogg');
      expect(mimeTypeForFilePath('a.flac'), 'audio/flac');
      expect(guessSyncContentType('book.epub'), 'application/epub+zip');
    });

    test('未知扩展名 / 无扩展名 / dotfile 回退 octet-stream', () {
      expect(mimeTypeForFilePath('a.bin'), kFallbackMimeType);
      expect(mimeTypeForFilePath('noext'), kFallbackMimeType);
      expect(mimeTypeForFilePath('.gitignore'), kFallbackMimeType);
      expect(mimeTypeForFilePath('dir.name/noext'), kFallbackMimeType);
      expect(mimeTypeForPath('noext'), kFallbackMimeType);
      expect(fallbackMimeType('a.bin'), kFallbackMimeType);
    });
  });

  group('表自身不变式', () {
    test('key 全小写、不含点；value 形如 type/subtype', () {
      final RegExp valueRe = RegExp(r'^[a-z0-9.+-]+/[a-z0-9.+-]+'
          r'(; charset=utf-8)?$');
      kMimeTypeByExtension.forEach((String ext, String mime) {
        expect(ext, ext.toLowerCase(), reason: 'key 必须小写：$ext');
        expect(ext.contains('.'), isFalse, reason: 'key 不含点：$ext');
        expect(valueRe.hasMatch(mime), isTrue, reason: '非法 MIME：$mime');
      });
    });

    test('webp 永远在表内（BUG-1122 防回退）', () {
      expect(kMimeTypeByExtension['webp'], 'image/webp');
    });
  });

  group('hibiki_anki 镜像守卫', () {
    test('kAnkiMimeTypeByExtension 与 hibiki_core 表逐项一致', () {
      expect(
        kAnkiMimeTypeByExtension,
        kMimeTypeByExtension,
        reason: 'hibiki_anki 是无 hibiki_core 依赖的独立模块，mimeTypeForPath '
            '持共享表的镜像副本；改动任一侧必须同步另一侧'
            '（真相源 packages/hibiki_core/lib/src/utils/mime_types.dart，'
            '镜像 packages/hibiki_anki/lib/src/anki_models.dart）。',
      );
    });

    test('镜像 lookup 行为与共享表一致（抽样）', () {
      for (final String ext in kMimeTypeByExtension.keys) {
        expect(mimeTypeForPath('f.$ext'), mimeTypeForFilePath('f.$ext'),
            reason: '扩展名 .$ext 两侧推断不一致');
      }
    });
  });

  group('源码扫描守卫：不得再新增扩展名→image MIME 的 switch 副本', () {
    test('lib 下 image 扩展名 case 标签只允许出现在白名单文件', () {
      final Directory root = _repoRoot();
      // 允许保留的例外（各自注释说明了不并表的原因）：
      // - manga_hibiki_page.dart：漫画图片服务，刻意 jpeg 兜底（非 octet-stream）。
      //   PR#474 把实现从 `pages/implementations/` 搬到 `media/manga/reader/`
      //   （旧路径只剩 3 行 re-export shim），`_mangaMimeForPath` 逐字未变，
      //   所以豁免**跟随文件移动**，不是新开豁免；旧路径同时移出名单，免得
      //   将来真有人在那条路径上新写一份 switch 却被这条陈旧条目放行。
      const Set<String> allowlist = <String>{
        'hibiki/lib/src/media/manga/reader/manga_hibiki_page.dart',
      };
      final RegExp caseRe =
          RegExp(r"case\s+'\.?(?:png|jpe?g|webp|gif|svg)'\s*:");
      final List<String> offenders = <String>[];
      for (final String libDir in <String>[
        'hibiki/lib',
        'packages/hibiki_anki/lib',
        'packages/hibiki_core/lib',
        'packages/hibiki_audio/lib',
        'packages/hibiki_dictionary/lib',
        'packages/hibiki_platform/lib',
      ]) {
        final Directory dir = Directory('${root.path}/$libDir');
        if (!dir.existsSync()) continue;
        for (final FileSystemEntity e in dir.listSync(recursive: true)) {
          if (e is! File || !e.path.endsWith('.dart')) continue;
          final String rel =
              e.path.substring(root.path.length + 1).replaceAll('\\', '/');
          if (allowlist.contains(rel)) continue;
          if (caseRe.hasMatch(e.readAsStringSync())) offenders.add(rel);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: '发现新的扩展名→MIME switch 副本。请改查 hibiki_core 的单一映射表 '
            'mimeTypeForFilePath（packages/hibiki_core/lib/src/utils/'
            'mime_types.dart）；hibiki_anki 内请查 kAnkiMimeTypeByExtension 镜像。',
      );
    });
  });
}
