import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';
import 'package:xml/xml.dart';

import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/utils/net/app_user_agent.dart';

/// コミコ（comico.jp）`magazine_comic` 类型作品的补丁（BUG-2514）。
///
/// keiyoushi 的 `ja/comico` 扩展把作品 URL 硬编码成 `/comic/<id>`，对
/// `type: magazine_comic`（KADOKAWA 分冊版等）的作品，站点 API 回
/// `result.code=404`、扩展抛 "Not Found"。同一部作品换 `/magazine_comic/<id>/…`
/// 路由就 200；章节正文不是 `chapter.images` 而是 `chapter.epub.chapterEpubIncludedFile`
/// ——CDN 上**预解压**的 EPUB（OPF + xhtml + 明文 JPEG），不需要任何解密，只有
/// 根 URL 字符串用扩展本来就有的那把静态 AES key 加了密。
///
/// 这条链路在 Dart 侧复刻，五端共用；不改扩展、不改桥。实测细节（2026-09-13，
/// 作品 209156 免费章 19/20）：
/// - `epub.url`（整包）在 CDN 上是 `NoSuchKey`，`epub.decryptKey` 网页阅读器根本不用；
/// - AES 解出的字符串带 `#<epochMs>` 尾巴，必须切掉；
/// - 图片请求只认 URL 上的 CloudFront 签名（`Policy/Signature/Key-Pair-Id`），不看头；
///   签名约 1 小时过期，页表不落库、每次进章现拉；
/// - 付费未解锁章 `product` 200 但没有 `epub` 字段。
class ComicoMagazineComicQuirk {
  ComicoMagazineComicQuirk({
    http.Client Function()? clientFactory,
    DateTime Function()? now,
  }) : _clientFactory = clientFactory ?? createAppHttpIoClient,
       _now = now ?? DateTime.now;

  final http.Client Function() _clientFactory;
  final DateTime Function() _now;

  static const String apiUrl = 'https://api.comico.jp';

  /// 挂在 [OnlineMangaChapter.raw] / [MihonChapter] JSON 上的标记：这一章由本
  /// quirk 产出，取页也走本 quirk。
  static const String rawMarkerKey = 'fushiQuirk';
  static const String rawMarkerValue = 'comico_magazine_comic';

  // 与 keiyoushi Comico.kt 的 companion object 逐字一致。
  static const String _anonIp = '0.0.0.0';
  static const String _webKey = '9241d2f090d01716feac20ae08ba791a';
  static const String _aesKey = 'a7fc9dc89f2c873d79397f8a0028a4cd';
  static const String _acceptImage =
      'image/avif,image/jxl,image/webp,image/*,*/*';

  static final RegExp _contentIdPattern = RegExp(
    r'^/(?:comic|magazine_comic)/(\d+)(?:/|$)',
  );

  /// 这个源是不是 comico.jp。
  static bool matches(MihonSource source) {
    final String? host = Uri.tryParse(source.baseUrl)?.host;
    return host != null && (host == 'comico.jp' || host.endsWith('.comico.jp'));
  }

  /// 扩展抛的「Not Found」——`result.code=404` 经 `status()` 映射后的原话。
  static bool isNotFound(Object error) => '$error'.contains('Not Found');

  /// 章节是否由本 quirk 产出。
  static bool ownsChapter(Map<String, Object?> raw) =>
      raw[rawMarkerKey] == rawMarkerValue;

  /// `/comic/<id>` / `/magazine_comic/<id>/…` 里的作品 id；不认识的形态返回 null。
  static int? contentIdOf(String url) {
    final RegExpMatch? m = _contentIdPattern.firstMatch(url);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// 扩展 `String.decrypt()` 的 Dart 版：AES-256-CBC、全零 IV、PKCS7，再切掉
  /// `#<epochMs>` 尾巴（`comic` 类型的图片 URL 密文没有这条尾巴，上游因此没处理）。
  static String decrypt(String base64Text) {
    final Uint8List key = Uint8List.fromList(utf8.encode(_aesKey));
    final Uint8List iv = Uint8List(16);
    final PaddedBlockCipher cipher =
        PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
          ..init(
            false,
            PaddedBlockCipherParameters<CipherParameters?, CipherParameters?>(
              ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
              null,
            ),
          );
    final String plain = utf8.decode(cipher.process(base64Decode(base64Text)));
    final int hash = plain.indexOf('#');
    return hash < 0 ? plain : plain.substring(0, hash);
  }

  /// 扩展 `apiHeaders` 的 Dart 版。
  Map<String, String> apiHeaders({
    required String baseUrl,
    required String language,
  }) {
    final int time = _now().millisecondsSinceEpoch ~/ 1000;
    return <String, String>{
      'User-Agent': fushiUserAgent('manga-comico'),
      'Accept-Language': language,
      'Referer': '$baseUrl/',
      'Origin': baseUrl,
      'X-comico-request-time': '$time',
      'X-comico-check-sum': sha256
          .convert(utf8.encode('$_webKey$_anonIp$time'))
          .toString(),
      'X-comico-client-immutable-uid': _anonIp,
      'X-comico-client-accept-mature': 'Y',
      'X-comico-client-platform': 'web',
      'X-comico-client-store': 'other',
      'X-comico-client-os': 'aos',
    };
  }

  /// `GET /magazine_comic/<id>/episode` → 章节列表，形态与扩展 `chapterListParse`
  /// 一致（新 → 旧、锁章加 🔒 后缀、`chapter_number` 留空让 name 识别），只是 URL
  /// 前缀是 `magazine_comic` 并带上 [rawMarkerKey]。
  Future<List<MihonChapter>> chapters({
    required int contentId,
    required String baseUrl,
    required String language,
  }) async {
    final Map<String, Object?> data = await _getData(
      Uri.parse('$apiUrl/magazine_comic/$contentId/episode'),
      baseUrl: baseUrl,
      language: language,
    );
    final Map<String, Object?>? content = _map(
      _map(data['episode'])?['content'],
    );
    final List<Object?> raw =
        content?['chapters'] as List<Object?>? ?? const <Object?>[];
    final List<MihonChapter> chapters = <MihonChapter>[
      for (final Object? item in raw)
        if (_map(item) case final Map<String, Object?> chapter)
          _chapterFrom(chapter, contentId: contentId),
    ];
    return chapters.reversed.toList(growable: false);
  }

  /// `GET /magazine_comic/<id>/chapter/<n>/product` → 预解压 EPUB → 按 spine 序的
  /// 图片 URL（已带 CloudFront 签名，直接 GET 即是明文 JPEG）。
  Future<List<String>> pageUrls({
    required String chapterUrl,
    required String baseUrl,
    required String language,
  }) async {
    final Map<String, Object?> data = await _getData(
      Uri.parse('$apiUrl$chapterUrl'),
      baseUrl: baseUrl,
      language: language,
    );
    final Map<String, Object?>? chapter = _map(data['chapter']);
    // 有 images 的（普通 comic 走错到这里）照扩展的办法拼。
    final List<Object?>? images = chapter?['images'] as List<Object?>?;
    if (images != null && images.isNotEmpty) {
      return <String>[
        for (final Object? item in images)
          if (_map(item) case final Map<String, Object?> image)
            _imageUrl(image),
      ];
    }
    final Map<String, Object?>? included = _map(
      _map(chapter?['epub'])?['chapterEpubIncludedFile'],
    );
    if (included == null) {
      throw const ComicoQuirkException(
        'This chapter has no readable content (not purchased or not unlocked)',
      );
    }
    final String root =
        decrypt(included['url'].toString()) +
        (included['rootPath']?.toString() ?? '');
    final String query = '?${included['parameter']}';
    // 不追加 m2Parameter.optimize（`/dims/optimize`）：那是 CDN 重编码过的小图，
    // 原图同样 200，OCR 要原图。
    final http.Client client = _clientFactory();
    try {
      final String opf = await _getText(
        client,
        Uri.parse('$root${included['rootFileName']}$query'),
      );
      // 严格按 spine 序：直引图片的项直接用，xhtml 页拉一下取里面的
      // <img src> / <image xlink:href>。
      final List<String> pages = <String>[];
      for (final ({String href, bool isImage}) item in _spineItems(opf)) {
        if (item.isImage) {
          pages.add('$root${item.href}$query');
          continue;
        }
        final String xhtml = await _getText(
          client,
          Uri.parse('$root${item.href}$query'),
        );
        final String? image = _imageHrefIn(xhtml);
        if (image == null) continue;
        pages.add('$root${_resolve(item.href, image)}$query');
      }
      if (pages.isEmpty) {
        throw const ComicoQuirkException('EPUB spine has no pages');
      }
      return pages;
    } finally {
      client.close();
    }
  }

  /// 取一页字节。图片 URL 已带签名，只需 Accept 与 Referer。
  Future<Uint8List> fetchImage(String url, {required String baseUrl}) async {
    final http.Client client = _clientFactory();
    try {
      final http.Response response = await client.get(
        Uri.parse(url),
        headers: <String, String>{
          'User-Agent': fushiUserAgent('manga-comico'),
          'Accept': _acceptImage,
          'Referer': '$baseUrl/',
        },
      );
      if (response.statusCode != 200) {
        throw ComicoQuirkException(
          'Image request failed with HTTP ${response.statusCode}',
        );
      }
      return response.bodyBytes;
    } finally {
      client.close();
    }
  }

  // ── 内部 ─────────────────────────────────────────────────────────

  Future<Map<String, Object?>> _getData(
    Uri uri, {
    required String baseUrl,
    required String language,
  }) async {
    final http.Client client = _clientFactory();
    try {
      final http.Response response = await client.get(
        uri,
        headers: apiHeaders(baseUrl: baseUrl, language: language),
      );
      if (response.statusCode != 200) {
        throw ComicoQuirkException(
          'HTTP ${response.statusCode} for ${uri.path}',
        );
      }
      final Map<String, Object?>? body = _map(jsonDecode(response.body));
      final int code = (_map(body?['result'])?['code'] as num?)?.toInt() ?? 0;
      if (code != 200) {
        throw ComicoQuirkException(
          'comico API result.code=$code for ${uri.path}',
        );
      }
      final Map<String, Object?>? data = _map(body?['data']);
      if (data == null) throw const ComicoQuirkException('No data found');
      return data;
    } finally {
      client.close();
    }
  }

  Future<String> _getText(http.Client client, Uri uri) async {
    final http.Response response = await client.get(uri);
    if (response.statusCode != 200) {
      throw ComicoQuirkException('HTTP ${response.statusCode} for ${uri.path}');
    }
    return utf8.decode(response.bodyBytes);
  }

  static MihonChapter _chapterFrom(
    Map<String, Object?> chapter, {
    required int contentId,
  }) {
    final Map<String, Object?>? sales = _map(chapter['salesConfig']);
    final Map<String, Object?>? activity = _map(chapter['activity']);
    final bool available =
        sales?['free'] == true ||
        chapter['hasTrial'] == true ||
        activity?['rented'] == true ||
        activity?['unlocked'] == true;
    final String name = chapter['name']?.toString() ?? '';
    return MihonChapter(
      url: '/magazine_comic/$contentId/chapter/${chapter['id']}/product',
      name: available ? name : '$name$lockSuffix',
      uploadedAt:
          DateTime.tryParse(
            chapter['publishedAt']?.toString() ?? '',
          )?.millisecondsSinceEpoch ??
          0,
      number: 0,
    );
  }

  /// 扩展 `Comico.LOCK`：锁章名后缀。
  static const String lockSuffix = ' \u{1F512}';

  static String _imageUrl(Map<String, Object?> image) {
    final String url = decrypt(image['url'].toString());
    final Object? parameter = image['parameter'];
    return parameter == null ? url : '$url?$parameter';
  }

  /// spine 按序展开成 manifest 项（跳过 `linear="no"`）。
  static List<({String href, bool isImage})> _spineItems(String opf) {
    final XmlDocument doc = XmlDocument.parse(opf);
    final Map<String, XmlElement> manifest = <String, XmlElement>{
      for (final XmlElement item in doc.findAllElements('item'))
        if (item.getAttribute('id') case final String id) id: item,
    };
    bool isImage(XmlElement? item) {
      final String type = item?.getAttribute('media-type') ?? '';
      return type.contains('image') && !type.contains('svg');
    }

    final List<({String href, bool isImage})> out =
        <({String href, bool isImage})>[];
    for (final XmlElement ref in doc.findAllElements('itemref')) {
      if (ref.getAttribute('linear') == 'no') continue;
      final XmlElement? item = manifest[ref.getAttribute('idref')];
      final String? href = item?.getAttribute('href');
      if (item == null || href == null || href.isEmpty) continue;
      final XmlElement? fallback = manifest[item.getAttribute('fallback')];
      final String? fallbackHref = fallback?.getAttribute('href');
      if (isImage(item)) {
        out.add((href: href, isImage: true));
      } else if (isImage(fallback) && fallbackHref != null) {
        out.add((href: fallbackHref, isImage: true));
      } else {
        out.add((href: href, isImage: false));
      }
    }
    return out;
  }

  /// xhtml 里第一张图：`<img src>` 优先，其次 `<image xlink:href>`。
  static String? _imageHrefIn(String xhtml) {
    final XmlDocument doc = XmlDocument.parse(xhtml);
    for (final XmlElement img in doc.findAllElements('img')) {
      final String? src = img.getAttribute('src');
      if (src != null && src.isNotEmpty) return src;
    }
    for (final XmlElement image in doc.findAllElements('image')) {
      final String? href =
          image.getAttribute('xlink:href') ?? image.getAttribute('href');
      if (href != null && href.isNotEmpty) return href;
    }
    return null;
  }

  /// 把 xhtml 里的相对路径按 xhtml 自己所在目录解析回 OPF 根相对路径
  /// （`xhtml/p-001.xhtml` + `../image/i-001.jpg` → `image/i-001.jpg`）。
  /// 不处理以 `/` 开头的绝对路径与 URL 编码：EPUB 规范不允许前者，实测 OPF 也
  /// 没有。
  static String _resolve(String fromHref, String relative) {
    final List<String> base = fromHref.split('/')..removeLast();
    for (final String segment in relative.split('/')) {
      if (segment == '..') {
        if (base.isNotEmpty) base.removeLast();
      } else if (segment != '.' && segment.isNotEmpty) {
        base.add(segment);
      }
    }
    return base.join('/');
  }

  static Map<String, Object?>? _map(Object? value) =>
      value is Map ? value.cast<String, Object?>() : null;
}

class ComicoQuirkException implements Exception {
  const ComicoQuirkException(this.message);
  final String message;
  @override
  String toString() => 'ComicoQuirkException: $message';
}
