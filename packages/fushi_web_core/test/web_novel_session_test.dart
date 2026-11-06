// 网页小说正文提取 / 连载会话：回归向量（native/fushi_web_core/tests/vectors/article/）经
// Dart → FFI → Rust 跑一遍，与 cargo test 同一份期望值。找不到原生库就失败（硬依赖，不 skip）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_web_core/fushi_web_core.dart';
import 'package:fushi_web_core/testing.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(useDevFushiWebCoreLibrary);

  final Directory? vectors = locateWebCoreVectors();
  Uint8List input(String file) =>
      File('${vectors!.path}/article/inputs/$file').readAsBytesSync();
  List<Map<String, Object?>> cases() =>
      ((jsonDecode(
                    File(
                      '${vectors!.path}/article/expected.json',
                    ).readAsStringSync(),
                  )
                  as Map<String, Object?>)['cases']!
              as List<Object?>)
          .cast<Map<String, Object?>>();

  test('vector set is present', () {
    expect(vectors, isNotNull);
    expect(cases().length, greaterThanOrEqualTo(9));
  });

  test('regression vectors: extraction through FFI matches', () async {
    final List<String> failures = <String>[];
    for (final Map<String, Object?> c in cases()) {
      final String file = c['file']! as String;
      final Uri url = Uri.parse(c['url']! as String);
      final WebArticle a = await WebArticleExtractor.extract(input(file), url);
      final Map<String, Object?> got = <String, Object?>{
        'title': a.title,
        'workTitle': a.workTitle,
        'author': a.author,
        'lang': a.lang,
        'siteRule': a.siteRule,
        'method': a.method,
        'charset': a.charset,
        'workKey': a.workKey,
        'next': a.next,
        'prev': a.prev,
        'toc': a.toc,
      };
      final Map<String, Object?> expect_ = c['expect']! as Map<String, Object?>;
      for (final MapEntry<String, Object?> e in expect_.entries) {
        final bool ok = switch (e.key) {
          'minChars' => a.chars >= (e.value! as int),
          'excerptPrefix' => a.excerpt.startsWith(e.value! as String),
          'xhtmlContains' => (e.value! as List<Object?>).every(
            (Object? s) => a.xhtml.contains(s! as String),
          ),
          'xhtmlNotContains' => (e.value! as List<Object?>).every(
            (Object? s) => !a.xhtml.contains(s! as String),
          ),
          final String field => got[field] == e.value,
        };
        if (!ok) failures.add('$file @ $url: ${e.key} want ${e.value}');
      }
    }
    expect(failures, isEmpty);
  });

  test('work key from URL alone', () {
    expect(
      WebArticleExtractor.workKeyForUrl(
        Uri.parse('https://ncode.syosetu.com/n9669bk/10/'),
      ),
      'ncode.syosetu.com/n9669bk',
    );
    expect(
      WebArticleExtractor.workKeyForUrl(
        Uri.parse('https://www.jjwxc.net/onebook.php?novelid=2456&chapterid=9'),
      ),
      'jjwxc.net?novelid=2456',
    );
    expect(WebArticleExtractor.workKeyForUrl(Uri.parse('ftp://x/y')), isNull);
  });

  test('session: ingest, dedupe, snapshot round trip', () async {
    final WebNovelSession session = WebNovelSession.open();
    final WebNovelIngest first = await session.ingest(
      input('syosetu_n9669bk_1.html'),
      Uri.parse('https://ncode.syosetu.com/n9669bk/1/'),
    );
    expect(first.status, WebNovelIngestStatus.added);
    expect(first.index, 0);
    expect(first.tailNext, 'https://ncode.syosetu.com/n9669bk/2/');
    expect(first.article.xhtml, startsWith('<p>　俺は34歳'));

    final WebNovelIngest other = await session.ingest(
      input('kakuyomu_1177354054881165840_ep.html'),
      Uri.parse(
        'https://kakuyomu.jp/works/1177354054881165840/episodes/1177354054881168184',
      ),
    );
    expect(other.status, WebNovelIngestStatus.otherWork);

    final WebNovelIngest tenth = await session.ingest(
      input('syosetu_n9669bk_10.html'),
      Uri.parse('https://ncode.syosetu.com/n9669bk/10/'),
    );
    expect(tenth.status, WebNovelIngestStatus.added);
    expect(tenth.chapterCount, 2);

    final WebNovelSnapshot snap = session.snapshot();
    expect(snap.workKey, 'ncode.syosetu.com/n9669bk');
    expect(snap.workTitle, '無職転生　- 異世界行ったら本気だす -');
    expect(snap.chapters.map((WebNovelChapter c) => c.title), <String>[
      'プロローグ',
      '第九話「緊急家族会議」',
    ]);
    expect(snap.tailNext, 'https://ncode.syosetu.com/n9669bk/11/');
    session.close();
    expect(session.isClosed, isTrue);

    final WebNovelSession restored = WebNovelSession.open(snapshot: snap.raw);
    final WebNovelIngest again = await restored.ingest(
      input('syosetu_n9669bk_1.html'),
      Uri.parse('http://ncode.syosetu.com/n9669bk/1'),
    );
    expect(again.status, WebNovelIngestStatus.updated);
    expect(again.chapterCount, 2);
    restored.close();

    expect(
      () => WebNovelSession.open(snapshot: '{"type":"nope","version":1}'),
      throwsA(isA<FormatException>()),
    );
  });

  test('close while an ingest is in flight is deferred, not a crash', () async {
    final WebNovelSession session = WebNovelSession.open();
    final Future<WebNovelIngest> pending = session.ingest(
      input('syosetu_n9669bk_1.html'),
      Uri.parse('https://ncode.syosetu.com/n9669bk/1/'),
    );
    session.close();
    expect(session.isClosed, isTrue);
    expect((await pending).status, WebNovelIngestStatus.added);
    expect(() => session.snapshot(), throwsStateError);
  });

  test('bad url surfaces the Rust error', () async {
    await expectLater(
      WebArticleExtractor.extract(
        Uint8List.fromList(utf8.encode('<p>x</p>')),
        Uri.parse('file:///x'),
      ),
      throwsA(
        isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          contains('scheme'),
        ),
      ),
    );
  });

  // 端到端耗时：~200 KB 典型小说页（真实快照的段落重复拼接），含整页字节拷进原生内存、
  // 后台 isolate、FFI、帧拷回 Dart 堆与 UTF-8 / JSON 解码。
  test('end-to-end timing for a ~200 KB page', () async {
    final String html = utf8.decode(input('syosetu_n9669bk_10.html'));
    final int start = html.indexOf('<p id="L1">');
    final int end = html.indexOf('</div>', start);
    final String paragraphs = html.substring(start, end);
    final int paragraphBytes = utf8.encode(paragraphs).length;
    final StringBuffer body = StringBuffer();
    // 按 UTF-8 字节计（与 Rust 侧 synthetic_200k_page 同一页）。
    for (int bytes = 0; bytes < 170000; bytes += paragraphBytes) {
      body.write(paragraphs);
    }
    final Uint8List page = utf8.encode(
      html.substring(0, start) + body.toString() + html.substring(end),
    );
    expect(page.length, greaterThan(190000));
    for (final (String url, String label) in <(String, String)>[
      ('https://ncode.syosetu.com/n9669bk/10/', 'site'),
      ('https://mirror.example/n9669bk/10/', 'generic'),
    ]) {
      final List<int> micros = <int>[];
      WebArticle? last;
      for (int i = 0; i < 7; i++) {
        final Stopwatch sw = Stopwatch()..start();
        last = await WebArticleExtractor.extract(page, Uri.parse(url));
        micros.add(sw.elapsedMicroseconds);
      }
      micros.sort();
      final WebNovelSession session = WebNovelSession.open();
      final Stopwatch sw = Stopwatch()..start();
      await session.ingest(page, Uri.parse(url));
      final int ingestMicros = sw.elapsedMicroseconds;
      session.close();
      // ignore: avoid_print
      print(
        '[web novel e2e] $label: ${page.length ~/ 1024} KB → '
        '${last!.chars} chars, extract median ${micros[3] / 1000} ms '
        '(min ${micros.first / 1000}, max ${micros.last / 1000}); '
        'session ingest ${ingestMicros / 1000} ms',
      );
      expect(last.chars, greaterThan(20000));
    }
  });
}
