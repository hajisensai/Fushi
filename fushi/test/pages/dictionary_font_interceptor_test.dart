import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_webview_media.dart';
import 'package:path/path.dart' as p;

/// BUG-1868：`dictionaryFontWebResourceResponse` 是本次唯一一段**直接把磁盘字节吐给
/// WebView** 的代码。它的三道校验和 403/null 的分流原本全靠人眼，这里补上回归保护。
///
/// 三道校验缺一不可，各自挡的东西不同：
///   ① 目录白名单（`safeCustomFontPath` 先 canonicalize 再 isWithin）——挡 `..` 逃逸；
///   ② **当前配置条目**白名单——只有目录白名单的话，任何能影响注入 CSS 的人都能读走
///      该目录下的任意文件（那目录里常年躺着历次导入的字体）；
///   ③ 字体魔数——避免把任意文件当字体吐出去。
///
/// 另外钉两条容易在重构里被当成冗余抹掉的设计决策：
///   * 非本前缀的 URL 必须返回 **null**（这是「不影响 image:// / dictmedia:// 原有
///     分支」的唯一保证）；
///   * 拒绝时返回 **403 而不是 null**——null 会让请求穿透到真实网络，`fushi.local`
///     并不存在，于是变成一次 DNS 失败的干等，而不是干脆地失败让字体链回退。
void main() {
  late Directory allowed;
  late Directory outside;
  late File goodFont;

  /// 一个最小但合法的 TrueType 头（`00 01 00 00`），足够通过魔数校验。
  Uint8List ttfBytes() => Uint8List.fromList(<int>[
        0x00, 0x01, 0x00, 0x00, // sfnt version
        0x00, 0x01, // numTables
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      ]);

  setUp(() async {
    allowed = await Directory.systemTemp.createTemp('fushi_font_allow');
    outside = await Directory.systemTemp.createTemp('fushi_font_outside');
    goodFont = File(p.join(allowed.path, 'Good.ttf'));
    await goodFont.writeAsBytes(ttfBytes());
  });

  tearDown(() async {
    for (final Directory d in <Directory>[allowed, outside]) {
      if (d.existsSync()) await d.delete(recursive: true);
    }
  });

  Future<WebResourceResponse?> serve(
    String url, {
    Set<String>? whitelist,
  }) =>
      dictionaryFontWebResourceResponse(
        Uri.parse(url),
        allowedRoots: <String>[allowed.path],
        whitelistedPaths:
            whitelist ?? <String>{p.canonicalize(goodFont.path)},
      );

  test('非字体 URL 返回 null（原有 image:// / dictmedia:// 分支不受影响）', () async {
    expect(await serve('image://?dictionary=X&path=a.png'), isNull);
    expect(await serve('dictmedia://styles.css?dictionary=X'), isNull);
    expect(await serve('https://fushi.local/fonts/whatever'), isNull,
        reason: '阅读器自己的 /fonts/ 前缀不归本拦截器管');
    expect(await serve('https://example.com/x.ttf'), isNull);
  });

  test('白名单内 + 魔数合法 → 200，带 CORS 头与字节', () async {
    final WebResourceResponse? r = await serve(dictionaryFontUrl(goodFont.path));
    expect(r, isNotNull);
    expect(r!.statusCode, 200);
    expect(r.data, isNotNull);
    expect(r.data!.length, ttfBytes().length);
    expect(
      r.headers?['Access-Control-Allow-Origin'],
      '*',
      reason: '字体是强制 CORS 模式的子资源，弹窗文档与 fushi.local 从不同源，'
          '少了这个头字体会被静默拒绝（表现为「字体没生效」而不是报错）',
    );
  });

  test('URL 带内容版本戳，且版本戳不影响路径解析', () async {
    final String url = dictionaryFontUrl(goodFont.path);
    expect(url, contains('?v='),
        reason: '没有版本戳的话，用户用同名文件覆盖字体后 URL 一字不变，'
            '带着 max-age 的缓存可能继续供旧字节——相对内联模式的行为倒退');
    final WebResourceResponse? r = await serve(url);
    expect(r?.statusCode, 200);

    // 覆盖文件（改大小）后版本戳必须变，否则自动失效无从谈起。
    await goodFont.writeAsBytes(Uint8List.fromList(<int>[
      ...ttfBytes(),
      ...List<int>.filled(32, 0),
    ]));
    expect(dictionaryFontUrl(goodFont.path), isNot(url));
  });

  test('目录白名单之外 → 403（不是 null，也不是 200）', () async {
    final File out = File(p.join(outside.path, 'Outside.ttf'));
    await out.writeAsBytes(ttfBytes());
    final WebResourceResponse? r = await serve(
      dictionaryFontUrl(out.path),
      whitelist: <String>{p.canonicalize(out.path)},
    );
    expect(r, isNotNull, reason: '必须是明确的拒绝，不能返回 null 让请求穿透到网络');
    expect(r!.statusCode, 403);
  });

  test('路径逃逸（..）→ 403', () async {
    final String escaped =
        p.join(allowed.path, '..', p.basename(outside.path), 'Escaped.ttf');
    final File out = File(p.join(outside.path, 'Escaped.ttf'));
    await out.writeAsBytes(ttfBytes());
    final WebResourceResponse? r = await serve(
      dictionaryFontUrl(escaped),
      whitelist: <String>{p.canonicalize(escaped)},
    );
    expect(r?.statusCode, 403);
  });

  test('在目录白名单内、但不在当前配置条目里 → 403', () async {
    final File stray = File(p.join(allowed.path, 'Stray.ttf'));
    await stray.writeAsBytes(ttfBytes());
    final WebResourceResponse? r = await serve(
      dictionaryFontUrl(stray.path),
      // 配置里只有 Good.ttf
      whitelist: <String>{p.canonicalize(goodFont.path)},
    );
    expect(r?.statusCode, 403,
        reason: '目录白名单不够：那个目录里常年躺着历次导入的字体，'
            '只放行此刻确实配置了的路径才能把可读集合收敛到最小');
  });

  test('魔数不合法 → 403（不把任意文件当字体吐出去）', () async {
    final File fake = File(p.join(allowed.path, 'Fake.ttf'));
    await fake.writeAsBytes(Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]));
    final WebResourceResponse? r = await serve(
      dictionaryFontUrl(fake.path),
      whitelist: <String>{p.canonicalize(fake.path)},
    );
    expect(r?.statusCode, 403);
  });

  test('文件不存在 → 403', () async {
    final String missing = p.join(allowed.path, 'Missing.ttf');
    final WebResourceResponse? r = await serve(
      '$kDictionaryFontUrlPrefix${Uri.encodeComponent(missing)}',
      whitelist: <String>{p.canonicalize(missing)},
    );
    expect(r?.statusCode, 403);
  });

  test('isDictionaryFontUrl 只认本前缀（拦截器靠它做廉价前缀判定）', () {
    expect(isDictionaryFontUrl(Uri.parse(dictionaryFontUrl(goodFont.path))),
        isTrue);
    expect(isDictionaryFontUrl(Uri.parse('image://?dictionary=X')), isFalse);
    expect(isDictionaryFontUrl(Uri.parse('https://fushi.local/fonts/x')),
        isFalse);
  });
}
