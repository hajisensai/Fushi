import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/scraper/sidecar_scanner.dart';
import 'package:path/path.dart' as p;

class _StubGeneratedArtifactChecker implements SidecarGeneratedArtifactChecker {
  const _StubGeneratedArtifactChecker(
      {required this.result, this.throwError = false});

  final bool result;
  final bool throwError;

  @override
  Future<bool> isUnmodifiedGeneratedArtifact(String absolutePath) async {
    if (throwError) {
      throw StateError('artifact lookup failed');
    }
    return result;
  }
}

void main() {
  late Directory tmp;
  late String videoPath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('hibiki_sidecar_');
    // 视频文件本身不需要真实存在，扫描只看同目录旁车资产。
    videoPath = p.join(tmp.path, 'My Show - 04 [1080p].mkv');
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  /// 在临时目录写一个占位文件（内容任意）。
  Future<void> writeFile(String name, [String content = 'x']) async {
    await File(p.join(tmp.path, name)).writeAsString(content);
  }

  group('SidecarScanner 海报识别', () {
    test('poster.jpg 优先于 folder.jpg', () async {
      await writeFile('folder.jpg');
      await writeFile('poster.jpg');

      final SidecarResult result = await SidecarScanner.scan(videoPath);

      expect(result.posterFile, isNotNull);
      expect(p.basename(result.posterFile!.path), 'poster.jpg');
    });

    test('folder 优先于 cover（无 poster 时）', () async {
      await writeFile('cover.png');
      await writeFile('folder.jpg');

      final SidecarResult result = await SidecarScanner.scan(videoPath);

      expect(p.basename(result.posterFile!.path), 'folder.jpg');
    });

    test('大小写不敏感（Poster.JPG 命中）', () async {
      await writeFile('Poster.JPG');

      final SidecarResult result = await SidecarScanner.scan(videoPath);

      expect(result.posterFile, isNotNull);
      expect(p.basename(result.posterFile!.path), 'Poster.JPG');
    });

    test('<片名>-poster.png 命中（Kodi 电影约定）', () async {
      await writeFile('My Show - 04 [1080p]-poster.png');

      final SidecarResult result = await SidecarScanner.scan(videoPath);

      expect(result.posterFile, isNotNull);
      expect(
        p.basename(result.posterFile!.path),
        'My Show - 04 [1080p]-poster.png',
      );
    });

    test('无任何海报返回 null', () async {
      await writeFile('random.txt');

      final SidecarResult result = await SidecarScanner.scan(videoPath);

      expect(result.posterFile, isNull);
    });

    test('artifact 与当前文件一致时保留命中并标记为 Hibiki 生成物', () async {
      await writeFile('poster.jpg', 'generated');

      final SidecarResult result = await SidecarScanner.scan(
        videoPath,
        generatedArtifactChecker:
            const _StubGeneratedArtifactChecker(result: true),
      );

      expect(result.posterFile, isNotNull);
      expect(result.posterIsUnmodifiedGeneratedArtifact, isTrue);
    });

    test('artifact 不存在或 hash 不一致时仍按用户 sidecar 处理', () async {
      await writeFile('poster.jpg', 'modified');

      final SidecarResult result = await SidecarScanner.scan(
        videoPath,
        generatedArtifactChecker:
            const _StubGeneratedArtifactChecker(result: false),
      );

      expect(result.posterFile, isNotNull);
      expect(result.posterIsUnmodifiedGeneratedArtifact, isFalse);
    });

    test('artifact 校验异常时保守按用户 sidecar 处理', () async {
      await writeFile('poster.jpg', 'unreadable ownership');

      final SidecarResult result = await SidecarScanner.scan(
        videoPath,
        generatedArtifactChecker: const _StubGeneratedArtifactChecker(
          result: false,
          throwError: true,
        ),
      );

      expect(result.posterFile, isNotNull);
      expect(result.posterIsUnmodifiedGeneratedArtifact, isFalse);
    });
  });

  group('SidecarScanner NFO 解析', () {
    test('tvshow.nfo 解析 title/year/uniqueid[tmdb]', () async {
      await writeFile('tvshow.nfo', '''
<?xml version="1.0" encoding="utf-8"?>
<tvshow>
  <title>鋼の錬金術師</title>
  <year>2009</year>
  <uniqueid type="tvdb">114801</uniqueid>
  <uniqueid type="tmdb">31911</uniqueid>
</tvshow>
''');

      final SidecarResult result = await SidecarScanner.scan(videoPath);

      expect(result.nfoTitle, '鋼の錬金術師');
      expect(result.nfoYear, 2009);
      expect(result.nfoTmdbId, '31911');
    });

    test('旧式 <tmdbid> 回退解析', () async {
      await writeFile('movie.nfo', '''
<movie>
  <title>君の名は。</title>
  <year>2016</year>
  <tmdbid>372058</tmdbid>
</movie>
''');

      final SidecarResult result = await SidecarScanner.scan(videoPath);

      expect(result.nfoTitle, '君の名は。');
      expect(result.nfoYear, 2016);
      expect(result.nfoTmdbId, '372058');
    });

    test('<片名>.nfo 优先于 tvshow.nfo', () async {
      await writeFile('My Show - 04 [1080p].nfo', '''
<episodedetails>
  <title>具体分集标题</title>
  <uniqueid type="tmdb">111</uniqueid>
</episodedetails>
''');
      await writeFile('tvshow.nfo', '''
<tvshow>
  <title>剧集级标题</title>
  <uniqueid type="tmdb">222</uniqueid>
</tvshow>
''');

      final SidecarResult result = await SidecarScanner.scan(videoPath);

      expect(result.nfoTitle, '具体分集标题');
      expect(result.nfoTmdbId, '111');
    });

    test('非法 XML 不抛出，回退全 null NFO', () async {
      await writeFile('tvshow.nfo', '<tvshow><title>坏 XML 没闭合');

      final SidecarResult result = await SidecarScanner.scan(videoPath);

      expect(result.nfoTitle, isNull);
      expect(result.nfoYear, isNull);
      expect(result.nfoTmdbId, isNull);
    });

    test('无 NFO 返回全 null', () async {
      final SidecarResult result = await SidecarScanner.scan(videoPath);

      expect(result.nfoTitle, isNull);
      expect(result.nfoYear, isNull);
      expect(result.nfoTmdbId, isNull);
    });
  });

  group('SidecarScanner 边界', () {
    test('目录不存在返回全 null，不抛出', () async {
      final String missing = p.join(tmp.path, 'no_such_dir', 'video.mkv');

      final SidecarResult result = await SidecarScanner.scan(missing);

      expect(result.posterFile, isNull);
      expect(result.nfoTitle, isNull);
      expect(result.nfoYear, isNull);
      expect(result.nfoTmdbId, isNull);
    });
  });
}
