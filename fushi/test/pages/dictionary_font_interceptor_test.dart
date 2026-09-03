import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/pages/implementations/dictionary_webview_media.dart';
import 'package:fushi/src/reader/dictionary_font_css.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';

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

  test('.ttc 在 URL 模式下的 Content-Type 与内联模式一致（font/collection）', () async {
    final File ttc = File(p.join(allowed.path, 'Collection.ttc'));
    // 'ttcf' 魔数：TrueType Collection。
    await ttc.writeAsBytes(Uint8List.fromList(<int>[
      0x74, 0x74, 0x63, 0x66, 0x00, 0x01, 0x00, 0x00,
    ]));
    final WebResourceResponse? r = await serve(
      dictionaryFontUrl(ttc.path),
      whitelist: <String>{p.canonicalize(ttc.path)},
    );
    expect(r?.statusCode, 200);
    expect(r?.contentType, 'font/collection',
        reason: '内联模式用 DictionaryFontCss._fontTypes 的 font/collection；'
            'URL 模式漏掉 .ttc 就会退化成 application/octet-stream，'
            '同一个字体文件两条注入路径 MIME 不一致');
  });

  // ── BUG-1868：白名单的**真实取值路径** ─────────────────────────────────
  //
  // 上面所有用例都把 whitelistedPaths 当实参手工构造，因此拦截器怎么**得到**这个
  // 集合从来没有被测过——PR #1014 把「注入侧读 ReaderSettings」与「拦截器侧读
  // ReaderSettings」写成两份判据、且拦截器那份漏了 DB 兜底，这条确定性的 Android
  // 回归就是这样零成本溜过去的。以下用例走 configuredDictionaryFontPaths 本体。
  group('configuredDictionaryFontPaths（生产取值路径）', () {
    late FushiDatabase db;
    late File disabledFont;
    late _PopupProcessAppModel appModel;

    setUp(() async {
      disabledFont = File(p.join(allowed.path, 'Disabled.ttf'));
      await disabledFont.writeAsBytes(ttfBytes());

      db = FushiDatabase.forTesting(NativeDatabase.memory());
      // 用 ReaderSettings 的公开写入 API 落真实持久化格式（font_catalog /
      // font_targets），而不是手工拼 JSON——手工拼的话格式一漂移这条测试就变成
      // 自说自话。
      final ReaderSettings seed = ReaderSettings(db);
      await seed.loadFromPrefsSnapshot(const <String, String>{});
      await seed.addFontForTarget(FontTarget.dictionary,
          name: 'Good', path: goodFont.path);
      await seed.addFontForTarget(FontTarget.dictionary,
          name: 'Disabled', path: disabledFont.path);
      await seed.toggleFontForTarget(FontTarget.dictionary, 1);

      final PreferencesRepository prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      appModel = _PopupProcessAppModel(db, prefs);

      // Android 独立 :popup 进程的恒定形态：initialiseForDictionaryPopup() 从不给
      // 这个静态赋值，所以它在那个进程里永远是 null。
      ReaderFushiSource.readerSettings = null;
    });

    tearDown(() async {
      ReaderFushiSource.readerSettings = null;
      await db.close();
    });

    test('readerSettings 为 null 但 DB 就绪时白名单非空（app 外查词字体不能失效）',
        () async {
      expect(ReaderFushiSource.readerSettings, isNull);
      final Set<String> whitelist = configuredDictionaryFontPaths(appModel);
      expect(whitelist, isNotEmpty,
          reason: '空白名单 = 注入的 CSS 引了字体、拦截器每条都回 403，'
              '词典字体在 app 外查词时静默失效（回退到 popup.css 硬编码字体）');
      expect(whitelist, contains(p.canonicalize(goodFont.path)));
    });

    test('停用的字体不进白名单（可读集合收敛到最小）', () {
      final Set<String> whitelist = configuredDictionaryFontPaths(appModel);
      expect(whitelist, isNot(contains(p.canonicalize(disabledFont.path))),
          reason: '产 CSS 的 DictionaryFontCss.build 过滤了 enabled==false；'
              '白名单不过滤的话，被用户停用的字体文件仍可经 /dictfonts/ 读出');
    });

    test('注入侧产的每条字体 URL，拦截器都必须放行（两侧同源的端到端断言）',
        () async {
      // 注入侧：与 popup_settings_injection 完全同一条取值 + 同一个 URL 构造器。
      final ReaderSettings? injected =
          ReaderFushiSource.resolveEffectiveReaderSettings(appModel);
      expect(injected, isNotNull);
      final ({String fontFamily, String fontFaces, List<String> families}) css =
          DictionaryFontCss.build(
        injected!.dictionaryFonts,
        allowedDirectories: <String>[allowed.path],
        fontUrlBuilder: dictionaryFontUrl,
      );
      final List<String> urls = RegExp(r'url\("([^"]+)"\)')
          .allMatches(css.fontFaces)
          .map((RegExpMatch m) => m.group(1)!)
          .toList();
      expect(urls, isNotEmpty,
          reason: '注入侧必须真的产出了 /dictfonts/ URL，否则这条断言是空转');

      // 拦截器侧：白名单来自生产取值路径，不是手工构造。
      final Set<String> whitelist = configuredDictionaryFontPaths(appModel);
      for (final String url in urls) {
        final WebResourceResponse? r = await dictionaryFontWebResourceResponse(
          Uri.parse(url),
          allowedRoots: <String>[allowed.path],
          whitelistedPaths: whitelist,
        );
        expect(r?.statusCode, 200,
            reason: 'CSS 里引了 $url，拦截器却拒绝供给 —— 正是「两边不一致」的哑失败');
      }
    });

    test('DB / prefs 未就绪时返回空集而不是抛异常', () {
      expect(configuredDictionaryFontPaths(_UnreadyAppModel()), isEmpty);
    });
  });
}

/// Android 独立 `:popup` 进程的 AppModel 形态：DB 与偏好仓库都就绪，但
/// `ReaderFushiSource.readerSettings` 恒为 null（`initialiseForDictionaryPopup()`
/// 从不给它赋值）。
class _PopupProcessAppModel extends AppModel {
  _PopupProcessAppModel(this._db, this._prefs) : super(testPlatformServices());

  final FushiDatabase _db;
  final PreferencesRepository _prefs;

  @override
  bool get isDatabaseReady => true;
  @override
  FushiDatabase get database => _db;
  @override
  bool get isPreferencesReady => true;
  @override
  PreferencesRepository get prefsRepo => _prefs;
}

/// 初始化早期 / 测试 seam：late 字段还没赋值，读它会抛 LateInitializationError。
class _UnreadyAppModel extends AppModel {
  _UnreadyAppModel() : super(testPlatformServices());
}
