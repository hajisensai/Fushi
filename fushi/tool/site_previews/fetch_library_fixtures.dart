// 下载并缓存一套公有领域 / CC 授权的作品素材，供集成测试播种 Fushi 的
// 书架 / 视频库 / 漫画库 / 游戏库（官网「App 全貌」截图用）。
//
// 用法（在 fushi/ 下）：
//   dart run tool/site_previews/fetch_library_fixtures.dart --out <缓存目录>
//     [--manifest tool/site_previews/library_sources.json]
//     [--proxy http://127.0.0.1:7890]   默认读 HTTPS_PROXY / HTTP_PROXY
//     [--ffmpeg ffmpeg]                 视频截取 / 静帧生成用
//     [--only id1,id2]                  只处理这些条目
//     [--update-manifest]               把下载实测的 sha256 写回清单
//
// 清单（library_sources.json）每项都写明授权、出处页与署名；脚本只按清单下载，
// 不做任何「搜一张图」的事。
//
// 产物（路径都相对 --out）：
//   _downloads/<id>/...       原始下载（sha256 对上就不再下载）
//   _state/<id>.json          派生产物的指纹（清单项或下载内容变了才重建）
//   books/<id>.epub|.jpg      青空文库 ruby txt → 带封面的最小 EPUB3（只取开头若干章）
//   videos/<id>.mp4|.jpg      官方小体积预告截一小段；没有就用海报生成 3 秒静帧
//   manga/<id>.cbz|.jpg       Pepper&Carrot 日文版每集一个 CBZ
//   games/<id>.jpg            游戏封面（不下载游戏本体）
//   library.json              {books, videos, manga, games}
//   ATTRIBUTION.txt           全部条目的授权与署名
//
// 青空文库原文是 Shift_JIS（CP932）。fushi 的依赖里没有纯 Dart 的 CP932 解码器，
// 这里依次尝试本机的 iconv / python / PowerShell 转码，全都不可用时该书报错。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// 派生产物格式变了就加一，让旧缓存的产物全部重建。
const int kGeneratorVersion = 4;

/// Wikimedia 的 User-Agent 政策要求可识别的 UA。
const String kUserAgent =
    'FushiLibraryFixtures/1.0 (https://github.com/hajisensai/fushi; site preview fixtures)';

/// 封面最长边（像素）。
const int kCoverMaxHeight = 1000;

/// 任一条目处理失败：信息里写清是哪一步。
class FixtureError implements Exception {
  FixtureError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 命令行参数。
class Options {
  Options({
    required this.outDir,
    required this.manifestPath,
    required this.proxy,
    required this.ffmpeg,
    required this.only,
    required this.updateManifest,
  });

  final String outDir;
  final String manifestPath;
  final String? proxy;
  final String ffmpeg;
  final Set<String> only;
  final bool updateManifest;
}

Options parseOptions(List<String> args) {
  String? out;
  String? manifest;
  String? proxy;
  String ffmpeg = 'ffmpeg';
  final Set<String> only = <String>{};
  bool update = false;
  for (int i = 0; i < args.length; i++) {
    final String a = args[i];
    String next() {
      if (i + 1 >= args.length) throw FixtureError('参数 $a 缺值');
      return args[++i];
    }

    switch (a) {
      case '--out':
        out = next();
      case '--manifest':
        manifest = next();
      case '--proxy':
        proxy = next();
      case '--ffmpeg':
        ffmpeg = next();
      case '--only':
        only.addAll(next().split(',').map((String s) => s.trim()));
      case '--update-manifest':
        update = true;
      default:
        throw FixtureError('未知参数: $a');
    }
  }
  if (out == null) throw FixtureError('必须给 --out <目录>');
  manifest ??= p.join(
    p.dirname(Platform.script.toFilePath()),
    'library_sources.json',
  );
  proxy ??= _envProxy();
  return Options(
    outDir: p.absolute(out),
    manifestPath: p.absolute(manifest),
    proxy: (proxy == null || proxy.isEmpty) ? null : proxy,
    ffmpeg: ffmpeg,
    only: only,
    updateManifest: update,
  );
}

String? _envProxy() {
  for (final String k in <String>[
    'HTTPS_PROXY',
    'https_proxy',
    'HTTP_PROXY',
    'http_proxy',
  ]) {
    final String? v = Platform.environment[k];
    if (v != null && v.isNotEmpty) return v;
  }
  return null;
}

// ---------------------------------------------------------------------------
// 下载
// ---------------------------------------------------------------------------

/// 一次下载的结果。
class FetchResult {
  FetchResult(this.path, this.sha256, {required this.fromCache});

  final String path;
  final String sha256;
  final bool fromCache;
}

/// 带代理、限速与 429 退避的下载器。所有下载串行执行。
class Downloader {
  Downloader(String? proxy) : _client = HttpClient() {
    _client.userAgent = kUserAgent;
    _client.connectionTimeout = const Duration(seconds: 30);
    if (proxy != null) {
      final Uri u = Uri.parse(proxy.contains('://') ? proxy : 'http://$proxy');
      _client.findProxy = (Uri _) => 'PROXY ${u.host}:${u.port}';
    }
  }

  final HttpClient _client;
  final Map<String, DateTime> _lastHit = <String, DateTime>{};
  int downloadedCount = 0;
  int cachedCount = 0;

  /// 同一 host 两次请求的最小间隔（Wikimedia 对缩略图限流很紧）。
  Duration _spacingFor(String host) => host.endsWith('wikimedia.org')
      ? const Duration(seconds: 3)
      : const Duration(milliseconds: 300);

  void close() => _client.close(force: true);

  /// 确保 [url] 已下载到 [dest]：已存在且 sha256 对上（或清单未钉值）就跳过。
  /// 钉了值但新下载的内容对不上时抛错，文件留作 `.rejected` 供人工核对。
  Future<FetchResult> ensure(
    String url,
    String expectedSha,
    String dest,
  ) async {
    final File f = File(dest);
    if (f.existsSync()) {
      final String sha = await sha256OfFile(dest);
      if (expectedSha.isEmpty || sha == expectedSha) {
        cachedCount++;
        return FetchResult(dest, sha, fromCache: true);
      }
      stdout.writeln('  ! 缓存 sha256 不符，重新下载: ${p.basename(dest)}');
    }
    f.parent.createSync(recursive: true);
    final String tmp = '$dest.part';
    await _download(Uri.parse(url), tmp);
    final String sha = await sha256OfFile(tmp);
    if (expectedSha.isNotEmpty && sha != expectedSha) {
      final String rejected = '$dest.rejected';
      if (File(rejected).existsSync()) File(rejected).deleteSync();
      File(tmp).renameSync(rejected);
      throw FixtureError(
        'sha256 不符: $url\n    期望 $expectedSha\n    实得 $sha\n'
        '    （文件留在 $rejected；核对内容无误后用 --update-manifest 重钉）',
      );
    }
    if (f.existsSync()) f.deleteSync();
    File(tmp).renameSync(dest);
    downloadedCount++;
    return FetchResult(dest, sha, fromCache: false);
  }

  Future<void> _download(Uri uri, String tmp) async {
    const int maxAttempts = 6;
    for (int attempt = 1; ; attempt++) {
      final DateTime? last = _lastHit[uri.host];
      final Duration spacing = _spacingFor(uri.host);
      if (last != null) {
        final Duration since = DateTime.now().difference(last);
        if (since < spacing) await Future<void>.delayed(spacing - since);
      }
      _lastHit[uri.host] = DateTime.now();
      try {
        final HttpClientRequest req = await _client.getUrl(uri);
        final HttpClientResponse res = await req.close().timeout(
          const Duration(seconds: 60),
        );
        if (res.statusCode == 200) {
          final IOSink sink = File(tmp).openWrite();
          await res.timeout(const Duration(seconds: 120)).pipe(sink);
          return;
        }
        await res.drain<void>();
        final bool retryable = res.statusCode == 429 || res.statusCode >= 500;
        if (!retryable || attempt >= maxAttempts) {
          throw FixtureError('HTTP ${res.statusCode}: $uri');
        }
        final int retryAfter =
            int.tryParse(res.headers.value('retry-after') ?? '') ??
            (10 * attempt);
        stdout.writeln(
          '  … HTTP ${res.statusCode}，$retryAfter 秒后重试（第 $attempt 次）',
        );
        await Future<void>.delayed(Duration(seconds: retryAfter));
      } on FixtureError {
        rethrow;
      } on Object catch (e) {
        if (attempt >= maxAttempts) throw FixtureError('下载失败 $uri: $e');
        stdout.writeln('  … 网络错误（$e），${5 * attempt} 秒后重试');
        await Future<void>.delayed(Duration(seconds: 5 * attempt));
      }
    }
  }
}

Future<String> sha256OfFile(String path) async {
  final Digest d = await sha256.bind(File(path).openRead()).first;
  return d.toString();
}

String sha256OfString(String s) => sha256.convert(utf8.encode(s)).toString();

// ---------------------------------------------------------------------------
// 清单
// ---------------------------------------------------------------------------

/// 清单里的一个可下载资源（文本 zip / 封面 / 视频 / 页图）。
class Asset {
  Asset(this.json);

  final Map<String, dynamic> json;

  String get url => json['url'] as String;
  String get sha256 => (json['sha256'] as String?) ?? '';
  set sha256(String v) => json['sha256'] = v;

  /// 裁剪框 [x0, y0, x1, y1]，按原图宽高的比例。
  List<double>? get crop => (json['crop'] as List<dynamic>?)
      ?.map((dynamic v) => (v as num).toDouble())
      .toList();

  /// 原始下载的扩展名（按 URL 推断）。
  String get extension {
    final String path = Uri.parse(url).path.toLowerCase();
    for (final String ext in <String>[
      '.jpg',
      '.jpeg',
      '.png',
      '.webp',
      '.zip',
      '.mp4',
      '.m4v',
      '.mov',
      '.ogg',
      '.webm',
    ]) {
      if (path.endsWith(ext)) return ext;
    }
    return '.bin';
  }
}

/// 一个条目的处理结果。
class ItemOutcome {
  ItemOutcome(this.id, this.kind, this.status, {this.entry, this.error});

  final String id;
  final String kind;

  /// built / cached / failed
  final String status;
  final Map<String, String>? entry;
  final String? error;
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

Future<void> main(List<String> args) async {
  final Options opt;
  try {
    opt = parseOptions(args);
  } on FixtureError catch (e) {
    stderr.writeln('参数错误: $e');
    exitCode = 64;
    return;
  }
  final Map<String, dynamic> manifest =
      jsonDecode(File(opt.manifestPath).readAsStringSync())
          as Map<String, dynamic>;
  final List<Map<String, dynamic>> items = (manifest['items'] as List<dynamic>)
      .cast<Map<String, dynamic>>();
  Directory(opt.outDir).createSync(recursive: true);
  stdout.writeln('清单: ${opt.manifestPath}');
  stdout.writeln('输出: ${opt.outDir}');
  stdout.writeln('代理: ${opt.proxy ?? '(无)'}');

  final Downloader dl = Downloader(opt.proxy);
  final List<ItemOutcome> outcomes = <ItemOutcome>[];
  bool manifestChanged = false;
  try {
    for (final Map<String, dynamic> item in items) {
      final String id = item['id'] as String;
      final String kind = item['kind'] as String;
      if (opt.only.isNotEmpty && !opt.only.contains(id)) continue;
      stdout.writeln('[$kind] $id');
      try {
        final _ItemRun run = _ItemRun(opt, dl, item);
        final ItemOutcome o = await run.process();
        manifestChanged |= run.manifestChanged;
        outcomes.add(o);
        stdout.writeln('  → ${o.status}');
      } on Object catch (e) {
        outcomes.add(ItemOutcome(id, kind, 'failed', error: '$e'));
        stdout.writeln('  ✗ 失败: $e');
      }
    }
  } finally {
    dl.close();
  }

  if (manifestChanged && opt.updateManifest) {
    File(opt.manifestPath).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
    );
    stdout.writeln('已把 sha256 写回清单。');
  } else if (manifestChanged) {
    stdout.writeln('清单里有未钉 sha256 的资源；核对后加 --update-manifest 写回。');
  }

  writeLibraryJson(opt.outDir, outcomes);
  writeAttribution(opt.outDir, items, outcomes);

  final int failed = outcomes
      .where((ItemOutcome o) => o.status == 'failed')
      .length;
  final int cached = outcomes
      .where((ItemOutcome o) => o.status == 'cached')
      .length;
  stdout.writeln('');
  stdout.writeln(
    '条目: ${outcomes.length}（缓存命中 $cached，重建 '
    '${outcomes.length - cached - failed}，失败 $failed）；'
    '下载 ${dl.downloadedCount} 个文件，命中下载缓存 ${dl.cachedCount} 个。',
  );
  stdout.writeln(
    '体积: 产物 ${formatBytes(dirSize(opt.outDir, excludeDownloads: true))}，'
    '含下载缓存共 ${formatBytes(dirSize(opt.outDir, excludeDownloads: false))}',
  );
  for (final ItemOutcome o in outcomes.where(
    (ItemOutcome o) => o.error != null,
  )) {
    stdout.writeln('  失败 ${o.id}: ${o.error}');
  }
  if (failed > 0) exitCode = 1;
}

/// 单个条目的下载 + 派生。
class _ItemRun {
  _ItemRun(this.opt, this.dl, this.item);

  final Options opt;
  final Downloader dl;
  final Map<String, dynamic> item;
  bool manifestChanged = false;

  String get id => item['id'] as String;
  String get kind => item['kind'] as String;
  String get title => item['title'] as String;
  String get downloadDir => p.join(opt.outDir, '_downloads', id);

  Future<FetchResult> fetch(Asset a, String name) async {
    final FetchResult r = await dl.ensure(
      a.url,
      a.sha256,
      p.join(downloadDir, '$name${a.extension}'),
    );
    if (!r.fromCache) {
      stdout.writeln('  下载 ${p.basename(r.path)}  sha256=${r.sha256}');
    }
    if (a.sha256.isEmpty) {
      a.sha256 = r.sha256;
      manifestChanged = true;
    }
    return r;
  }

  Future<ItemOutcome> process() async {
    switch (kind) {
      case 'book':
        return _book();
      case 'video':
        return _video();
      case 'manga':
        return _manga();
      case 'game':
        return _game();
      default:
        throw FixtureError('未知 kind: $kind');
    }
  }

  /// 派生产物都在、且指纹（清单项 + 下载内容 + 生成器版本）没变就跳过。
  bool _upToDate(String fingerprint, List<String> outputs) {
    final File state = File(p.join(opt.outDir, '_state', '$id.json'));
    if (!state.existsSync()) return false;
    final Map<String, dynamic> s =
        jsonDecode(state.readAsStringSync()) as Map<String, dynamic>;
    if (s['fingerprint'] != fingerprint) return false;
    return outputs.every(
      (String rel) => File(p.join(opt.outDir, rel)).existsSync(),
    );
  }

  void _markBuilt(String fingerprint) {
    final File state = File(p.join(opt.outDir, '_state', '$id.json'));
    state.parent.createSync(recursive: true);
    state.writeAsStringSync(
      jsonEncode(<String, String>{'fingerprint': fingerprint}),
    );
  }

  String _fingerprint(List<FetchResult> inputs) => sha256OfString(
    jsonEncode(<String, Object>{
      'v': kGeneratorVersion,
      'item': item,
      'inputs': inputs.map((FetchResult r) => r.sha256).toList(),
    }),
  );

  String _out(String rel) {
    final String abs = p.join(opt.outDir, rel);
    File(abs).parent.createSync(recursive: true);
    return abs;
  }

  Future<ItemOutcome> _book() async {
    final Asset text = Asset(item['text'] as Map<String, dynamic>);
    final Asset cover = Asset(item['cover'] as Map<String, dynamic>);
    final FetchResult t = await fetch(text, 'text');
    final FetchResult c = await fetch(cover, 'cover');
    final String epubRel = 'books/$id.epub';
    final String coverRel = 'books/$id.jpg';
    final Map<String, String> entry = <String, String>{
      'title': title,
      'author': item['author'] as String,
      'epub': epubRel,
      'cover': coverRel,
    };
    final String fp = _fingerprint(<FetchResult>[t, c]);
    if (_upToDate(fp, <String>[epubRel, coverRel])) {
      return ItemOutcome(id, kind, 'cached', entry: entry);
    }
    final Uint8List coverJpg = makeCoverJpeg(
      File(c.path).readAsBytesSync(),
      cover.crop,
    );
    File(_out(coverRel)).writeAsBytesSync(coverJpg);
    final String raw = await resolveAozoraGaiji(
      await decodeShiftJis(readAozoraTxt(t.path)),
    );
    final AozoraDoc doc = parseAozora(raw);
    final Uint8List epub = buildEpub(
      id: id,
      title: title,
      author: item['author'] as String,
      doc: doc,
      maxChars: (text.json['maxChars'] as num?)?.toInt() ?? 30000,
      coverJpeg: coverJpg,
      sourcePage: item['sourcePage'] as String,
      coverCredit: cover.json['attribution'] as String,
      coverSourcePage: cover.json['sourcePage'] as String,
    );
    File(_out(epubRel)).writeAsBytesSync(epub);
    _markBuilt(fp);
    return ItemOutcome(id, kind, 'built', entry: entry);
  }

  Future<ItemOutcome> _video() async {
    final Asset cover = Asset(item['cover'] as Map<String, dynamic>);
    final Map<String, dynamic>? clipJson =
        item['clip'] as Map<String, dynamic>?;
    final FetchResult c = await fetch(cover, 'cover');
    final List<FetchResult> inputs = <FetchResult>[c];
    FetchResult? clip;
    if (clipJson != null) {
      clip = await fetch(Asset(clipJson), 'trailer');
      inputs.add(clip);
    }
    final String fileRel = 'videos/$id.mp4';
    final String coverRel = 'videos/$id.jpg';
    final Map<String, String> entry = <String, String>{
      'title': title,
      'file': fileRel,
      'cover': coverRel,
    };
    final String fp = _fingerprint(inputs);
    if (_upToDate(fp, <String>[fileRel, coverRel])) {
      return ItemOutcome(id, kind, 'cached', entry: entry);
    }
    final String coverAbs = _out(coverRel);
    File(coverAbs).writeAsBytesSync(
      makeCoverJpeg(File(c.path).readAsBytesSync(), cover.crop),
    );
    final String outAbs = _out(fileRel);
    if (clip != null) {
      await runFfmpeg(opt.ffmpeg, <String>[
        '-ss',
        '${(clipJson!['start'] as num?) ?? 0}',
        '-i',
        clip.path,
        '-t',
        '${(clipJson['duration'] as num?) ?? 6}',
        '-vf',
        'scale=-2:360,format=yuv420p',
        '-c:v',
        'libx264',
        '-preset',
        'veryfast',
        '-crf',
        '26',
        '-c:a',
        'aac',
        '-b:a',
        '96k',
        '-ac',
        '2',
        '-map_metadata',
        '-1',
        '-movflags',
        '+faststart',
        outAbs,
      ]);
    } else {
      await runFfmpeg(opt.ffmpeg, <String>[
        '-loop',
        '1',
        '-framerate',
        '24',
        '-i',
        coverAbs,
        '-f',
        'lavfi',
        '-i',
        'anullsrc=channel_layout=stereo:sample_rate=48000',
        '-t',
        '3',
        '-vf',
        'scale=1280:720:force_original_aspect_ratio=decrease,'
            'pad=1280:720:(ow-iw)/2:(oh-ih)/2:black,format=yuv420p',
        '-c:v',
        'libx264',
        '-tune',
        'stillimage',
        '-preset',
        'veryfast',
        '-crf',
        '28',
        '-c:a',
        'aac',
        '-b:a',
        '64k',
        '-shortest',
        '-map_metadata',
        '-1',
        '-movflags',
        '+faststart',
        outAbs,
      ]);
    }
    _markBuilt(fp);
    return ItemOutcome(id, kind, 'built', entry: entry);
  }

  Future<ItemOutcome> _manga() async {
    final List<Asset> pages = (item['pages'] as List<dynamic>)
        .map((dynamic j) => Asset(j as Map<String, dynamic>))
        .toList();
    if (pages.isEmpty) throw FixtureError('漫画条目没有页');
    final List<FetchResult> inputs = <FetchResult>[];
    for (int i = 0; i < pages.length; i++) {
      inputs.add(
        await fetch(pages[i], 'p${(i + 1).toString().padLeft(3, '0')}'),
      );
    }
    final String cbzRel = 'manga/$id.cbz';
    final String coverRel = 'manga/$id.jpg';
    final Map<String, String> entry = <String, String>{
      'title': title,
      'series': item['series'] as String,
      'cbz': cbzRel,
      'cover': coverRel,
    };
    final String fp = _fingerprint(inputs);
    if (_upToDate(fp, <String>[cbzRel, coverRel])) {
      return ItemOutcome(id, kind, 'cached', entry: entry);
    }
    final Archive cbz = Archive();
    for (int i = 0; i < inputs.length; i++) {
      final Uint8List bytes = File(inputs[i].path).readAsBytesSync();
      final String name =
          '${(i + 1).toString().padLeft(3, '0')}${p.extension(inputs[i].path)}';
      cbz.addFile(ArchiveFile.noCompress(name, bytes.length, bytes));
    }
    cbz.addFile(
      _textFile(
        'ATTRIBUTION.txt',
        '$title\n${item['attribution']}\n'
            'License: ${(item['license'] as Map<String, dynamic>)['name']} '
            '${(item['license'] as Map<String, dynamic>)['url']}\n'
            'Source: ${item['sourcePage']}\n',
      ),
    );
    File(_out(cbzRel)).writeAsBytesSync(_zip(cbz));
    File(_out(coverRel)).writeAsBytesSync(
      makeCoverJpeg(File(inputs.first.path).readAsBytesSync(), null),
    );
    _markBuilt(fp);
    return ItemOutcome(id, kind, 'built', entry: entry);
  }

  Future<ItemOutcome> _game() async {
    final Asset cover = Asset(item['cover'] as Map<String, dynamic>);
    final FetchResult c = await fetch(cover, 'cover');
    final String coverRel = 'games/$id.jpg';
    final Map<String, String> entry = <String, String>{
      'title': title,
      'cover': coverRel,
    };
    final String fp = _fingerprint(<FetchResult>[c]);
    if (_upToDate(fp, <String>[coverRel])) {
      return ItemOutcome(id, kind, 'cached', entry: entry);
    }
    File(_out(coverRel)).writeAsBytesSync(
      makeCoverJpeg(File(c.path).readAsBytesSync(), cover.crop),
    );
    _markBuilt(fp);
    return ItemOutcome(id, kind, 'built', entry: entry);
  }
}

// ---------------------------------------------------------------------------
// 图片 / ffmpeg
// ---------------------------------------------------------------------------

/// 解码 → 按比例裁剪 → 缩到最长边 [kCoverMaxHeight] 以内 → JPEG。
Uint8List makeCoverJpeg(Uint8List source, List<double>? crop) {
  img.Image? im = img.decodeImage(source);
  if (im == null) throw FixtureError('封面图解码失败');
  if (crop != null) {
    if (crop.length != 4) throw FixtureError('crop 必须是 [x0, y0, x1, y1]');
    final int x0 = (crop[0] * im.width).round();
    final int y0 = (crop[1] * im.height).round();
    final int x1 = (crop[2] * im.width).round();
    final int y1 = (crop[3] * im.height).round();
    if (x1 <= x0 || y1 <= y0) throw FixtureError('crop 区域为空: $crop');
    im = img.copyCrop(im, x: x0, y: y0, width: x1 - x0, height: y1 - y0);
  }
  final int longest = im.width > im.height ? im.width : im.height;
  if (longest > kCoverMaxHeight) {
    im = im.width >= im.height
        ? img.copyResize(
            im,
            width: kCoverMaxHeight,
            interpolation: img.Interpolation.average,
          )
        : img.copyResize(
            im,
            height: kCoverMaxHeight,
            interpolation: img.Interpolation.average,
          );
  }
  if (im.numChannels == 4) {
    im = im.convert(numChannels: 3);
  }
  return img.encodeJpg(im, quality: 86);
}

Future<void> runFfmpeg(String ffmpeg, List<String> args) async {
  final ProcessResult r = await Process.run(ffmpeg, <String>[
    '-hide_banner',
    '-loglevel',
    'error',
    '-y',
    ...args,
  ]);
  if (r.exitCode != 0) {
    throw FixtureError('ffmpeg 失败（${r.exitCode}）: ${r.stderr}');
  }
}

// ---------------------------------------------------------------------------
// 青空文库
// ---------------------------------------------------------------------------

/// 取青空文库 zip 里唯一的 .txt（Shift_JIS 原始字节）。
Uint8List readAozoraTxt(String zipPath) {
  final Archive a = ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());
  final List<ArchiveFile> txts = a.files
      .where(
        (ArchiveFile f) => f.isFile && f.name.toLowerCase().endsWith('.txt'),
      )
      .toList();
  if (txts.length != 1) {
    throw FixtureError('青空文库 zip 里应恰有一个 .txt，实有 ${txts.length}: $zipPath');
  }
  return Uint8List.fromList(txts.single.content as List<int>);
}

/// CP932 → String。按顺序试 iconv / python / PowerShell，第一个成功的为准。
Future<String> decodeShiftJis(Uint8List bytes) => decodeExternal(
  bytes,
  label: 'CP932',
  iconvCharset: 'CP932',
  pythonCodec: 'cp932',
  dotnetCodePage: 932,
);

/// 用本机外部工具把 [bytes] 按某个日文编码解成 String（fushi 依赖里没有纯 Dart
/// 的日文编码解码器）。[dotnetCodePage] 为 null 时不试 PowerShell（.NET 不支持
/// JIS X 0213）。
Future<String> decodeExternal(
  Uint8List bytes, {
  required String label,
  required String iconvCharset,
  required String pythonCodec,
  int? dotnetCodePage,
}) async {
  final String py =
      'import sys;sys.stdout.buffer.write(sys.stdin.buffer.read()'
      '.decode("$pythonCodec").encode("utf-8"))';
  final List<List<String>> candidates = <List<String>>[
    <String>['iconv', '-f', iconvCharset, '-t', 'UTF-8'],
    <String>['python3', '-I', '-c', py],
    <String>['python', '-I', '-c', py],
    if (Platform.isWindows && dotnetCodePage != null)
      for (final String ps in <String>['pwsh', 'powershell'])
        <String>[
          ps,
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'$in=[Console]::OpenStandardInput();$ms=New-Object IO.MemoryStream;'
              r'$in.CopyTo($ms);$t=[Text.Encoding]::GetEncoding('
              '$dotnetCodePage'
              r').GetString($ms.ToArray());'
              r'$o=[Console]::OpenStandardOutput();$b=[Text.Encoding]::UTF8.GetBytes($t);'
              r'$o.Write($b,0,$b.Length);$o.Flush()',
        ],
  ];
  final List<String> errors = <String>[];
  for (final List<String> cmd in candidates) {
    try {
      final Process proc = await Process.start(cmd.first, cmd.sublist(1));
      final Future<List<int>> outF = proc.stdout.fold<List<int>>(
        <int>[],
        (List<int> acc, List<int> chunk) => acc..addAll(chunk),
      );
      final Future<String> errF = proc.stderr.transform(utf8.decoder).join();
      // 候选进程可能一启动就退出（例如 Windows 上 WindowsApps 里的 python3
      // 占位程序），这时写 stdin 会报管道已关闭；以退出码为准换下一个候选。
      String stdinError = '';
      try {
        proc.stdin.add(bytes);
        await proc.stdin.close();
      } on Object catch (e) {
        stdinError = ' (stdin: $e)';
      }
      final int code = await proc.exitCode;
      final List<int> out = await outF;
      final String err = await errF;
      if (code == 0 && out.isNotEmpty && stdinError.isEmpty) {
        return utf8.decode(out);
      }
      errors.add('${cmd.first}: exit $code ${err.trim()}$stdinError');
    } on ProcessException catch (e) {
      errors.add('${cmd.first}: ${e.message}');
    }
  }
  throw FixtureError(
    '没有可用的 $label 解码器（iconv / python / PowerShell）:\n  ${errors.join('\n  ')}',
  );
}

/// 青空文库对无 JIS 编码的约物用固定名称注记（「感嘆符三つ、63-8」这类，
/// 后面只跟底本页行号），按名称换成等价字符。
const Map<String, String> _namedGaiji = <String, String>{
  '感嘆符二つ': '‼',
  '感嘆符三つ': '!!!',
  '疑問符二つ': '⁇',
  '疑問符感嘆符': '⁈',
  '感嘆符疑問符': '⁉',
};

/// 不含嵌套的外字注记 `※［＃…］`（嵌套的由内向外逐层替换）。
final RegExp _gaijiInnermost = RegExp(r'※［＃([^［］]*)］');

/// 外字注记里的 JIS X 0213 面区点：`第3水準1-86-49` / `第4水準2-13-28` / `1-2-22`。
final RegExp _menKuTen = RegExp(r'(?:第[34]水準)?([12])-(\d{1,2})-(\d{1,2})］$');

/// 把外字注记换成真字：有 `U+XXXX` 的直接换；只有 JIS X 0213 面区点的，
/// 按 EUC-JIS-2004 拼字节交给外部解码器批量换；都没有（或本机无解码器）的
/// 换成〓。嵌套注记（注记里再套外字）由内向外逐层处理。
Future<String> resolveAozoraGaiji(String text) async {
  final Set<String> codes = <String>{};
  for (final Match m in RegExp(r'※［＃[^］]*］').allMatches(text)) {
    final Match? k = _menKuTen.firstMatch(m.group(0)!);
    if (k != null) codes.add('${k.group(1)}-${k.group(2)}-${k.group(3)}');
  }
  final Map<String, String> resolved = <String, String>{};
  if (codes.isNotEmpty) {
    final List<String> ordered = codes.toList();
    final BytesBuilder eucBytes = BytesBuilder();
    for (final String c in ordered) {
      final List<int> parts = c.split('-').map(int.parse).toList();
      if (parts[0] == 2) eucBytes.addByte(0x8F);
      eucBytes
        ..addByte(0xA0 + parts[1])
        ..addByte(0xA0 + parts[2])
        ..addByte(0x0A);
    }
    try {
      final List<String> chars = (await decodeExternal(
        eucBytes.takeBytes(),
        label: 'EUC-JIS-2004',
        iconvCharset: 'EUC-JISX0213',
        pythonCodec: 'euc_jis_2004',
      )).split('\n');
      for (int i = 0; i < ordered.length && i < chars.length; i++) {
        if (chars[i].isNotEmpty) resolved[ordered[i]] = chars[i];
      }
    } on FixtureError catch (e) {
      stdout.writeln('  ! JIS X 0213 外字无法解码，改用〓: $e');
    }
  }
  String out = text;
  int unresolved = 0;
  while (true) {
    bool changed = false;
    out = out.replaceAllMapped(_gaijiInnermost, (Match m) {
      changed = true;
      final String note = m.group(0)!;
      final Match? u = _unicodeRef.firstMatch(note);
      if (u != null) {
        return String.fromCharCode(int.parse(u.group(1)!, radix: 16));
      }
      final Match? k = _menKuTen.firstMatch(note);
      final String? hit = k == null
          ? null
          : resolved['${k.group(1)}-${k.group(2)}-${k.group(3)}'];
      if (hit != null) return hit;
      for (final MapEntry<String, String> named in _namedGaiji.entries) {
        if (note.startsWith('※［＃${named.key}、')) return named.value;
      }
      unresolved++;
      return '〓';
    });
    if (!changed) break;
  }
  if (unresolved > 0) stdout.writeln('  外字 $unresolved 处无编码可查，已换成〓');
  return out;
}

/// 解析后的青空文库文档。
class AozoraDoc {
  AozoraDoc(this.chapters, this.colophon);

  final List<AozoraChapter> chapters;

  /// 「底本：」起到文末的原文行（入力・校正等クレジット，原样保留）。
  final List<String> colophon;
}

/// 以见出し切开的一段正文。连续的见出し（大见出し后紧跟中见出し）归入同一章。
class AozoraChapter {
  /// 本章各见出し的纯文本（目录用）。
  final List<String> headingLabels = <String>[];

  /// 已渲染好的块级元素（`<hN>` 见出し与 `<p>` 段落）。
  final List<String> blocksHtml = <String>[];
  int paragraphCount = 0;
  int plainChars = 0;

  bool get isEmpty => blocksHtml.isEmpty;

  void addHeading(String html, int level) {
    headingLabels.add(_plainText(html));
    blocksHtml.add('<h$level>$html</h$level>');
  }

  void addParagraph(String html) {
    blocksHtml.add('<p>$html</p>');
    paragraphCount++;
    plainChars += _plainText(html).length;
  }
}

final RegExp _annotation = RegExp(r'［＃[^］]*］');
final RegExp _gaiji = RegExp(r'※［＃([^］]*)］');
final RegExp _unicodeRef = RegExp(r'U\+([0-9A-Fa-f]{4,6})');

AozoraDoc parseAozora(String text) {
  final List<String> lines = const LineSplitter().convert(
    text.replaceFirst(String.fromCharCode(0xFEFF), ''),
  );
  int i = 0;
  // 标题 / 作者等行：到第一个空行为止。
  while (i < lines.length && lines[i].trim().isNotEmpty) {
    i++;
  }
  while (i < lines.length && lines[i].trim().isEmpty) {
    i++;
  }
  // 【テキスト中に現れる記号について】说明块。
  if (i < lines.length && lines[i].startsWith('-----')) {
    i++;
    while (i < lines.length && !lines[i].startsWith('-----')) {
      i++;
    }
    i++;
  }
  final List<AozoraChapter> chapters = <AozoraChapter>[AozoraChapter()];
  final List<String> colophon = <String>[];
  for (; i < lines.length; i++) {
    final String line = lines[i];
    if (line.startsWith('底本：')) {
      colophon.addAll(
        lines.sublist(i).where((String l) => l.trim().isNotEmpty),
      );
      break;
    }
    final bool isHeading = line.contains('見出し］') || line.contains('見出し終わり］');
    final String html = aozoraInlineToXhtml(line).trim();
    if (html.isEmpty) continue;
    if (isHeading) {
      if (chapters.last.paragraphCount > 0) chapters.add(AozoraChapter());
      chapters.last.addHeading(html, line.contains('大見出し') ? 2 : 3);
      continue;
    }
    chapters.last.addParagraph(html);
  }
  chapters.removeWhere((AozoraChapter c) => c.isEmpty);
  return AozoraDoc(chapters, colophon);
}

/// 去掉 `<rt>` 读音与全部标签后的纯文本。
String _plainText(String html) => html
    .replaceAll(RegExp(r'<rt>.*?</rt>'), '')
    .replaceAll(RegExp(r'<[^>]+>'), '');

String escapeXml(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// 一行青空文库记法 → XHTML 片段：外字按 Unicode 注记替换（无注记的用〓），
/// 其它［＃…］注记删除，`｜親字《ルビ》` / `漢字《かんじ》` 转 `<ruby>`。
String aozoraInlineToXhtml(String line) {
  String s = line.replaceAllMapped(_gaiji, (Match m) {
    final Match? u = _unicodeRef.firstMatch(m.group(1)!);
    return u == null
        ? '〓'
        : String.fromCharCode(int.parse(u.group(1)!, radix: 16));
  });
  s = s.replaceAll(_annotation, '');
  final StringBuffer out = StringBuffer();
  final StringBuffer pending = StringBuffer();
  int bar = -1;
  int i = 0;
  while (i < s.length) {
    final String ch = s[i];
    if (ch == '｜') {
      bar = pending.length;
      i++;
      continue;
    }
    if (ch == '《') {
      final int close = s.indexOf('》', i + 1);
      if (close > i + 1) {
        final String reading = s.substring(i + 1, close);
        final String buf = pending.toString();
        final int start = bar >= 0 ? bar : _rubyBaseStart(buf);
        if (start < buf.length) {
          out
            ..write(escapeXml(buf.substring(0, start)))
            ..write('<ruby>')
            ..write(escapeXml(buf.substring(start)))
            ..write('<rt>')
            ..write(escapeXml(reading))
            ..write('</rt></ruby>');
          pending.clear();
          bar = -1;
          i = close + 1;
          continue;
        }
      }
    }
    pending.write(ch);
    i++;
  }
  out.write(escapeXml(pending.toString()));
  return out.toString();
}

/// 隐式ルビ的親字 = 《 前同一字种的连续字符（汉字 / 片假名 / 平假名 / 拉丁字母）。
int _rubyBaseStart(String buf) {
  if (buf.isEmpty) return 0;
  final List<int> runes = buf.runes.toList();
  final int cls = _charClass(runes.last);
  if (cls == 0) return buf.length;
  int k = runes.length;
  while (k > 0 && _charClass(runes[k - 1]) == cls) {
    k--;
  }
  return String.fromCharCodes(runes.sublist(0, k)).length;
}

/// 1 汉字、2 片假名、3 平假名、4 拉丁字母数字（含全角），0 其它。
int _charClass(int r) {
  if ((r >= 0x4E00 && r <= 0x9FFF) ||
      (r >= 0x3400 && r <= 0x4DBF) ||
      (r >= 0xF900 && r <= 0xFAFF) ||
      (r >= 0x20000 && r <= 0x3FFFF) ||
      r == 0x3005 || // 々
      r == 0x303B || // 〻
      r == 0x3006 || // 〆
      r == 0x3007 || // 〇
      r == 0x30F6 || // ヶ
      r == 0x4EDD || // 仝
      r == 0x3013) {
    // 〓
    return 1;
  }
  if ((r >= 0x30A1 && r <= 0x30FA) || r == 0x30FC) return 2;
  if (r >= 0x3041 && r <= 0x309F) return 3;
  if ((r >= 0x30 && r <= 0x39) ||
      (r >= 0x41 && r <= 0x5A) ||
      (r >= 0x61 && r <= 0x7A) ||
      (r >= 0xFF10 && r <= 0xFF19) ||
      (r >= 0xFF21 && r <= 0xFF3A) ||
      (r >= 0xFF41 && r <= 0xFF5A)) {
    return 4;
  }
  return 0;
}

// ---------------------------------------------------------------------------
// EPUB3
// ---------------------------------------------------------------------------

const String _css = '''
@charset "UTF-8";
html { writing-mode: vertical-rl; -webkit-writing-mode: vertical-rl; -epub-writing-mode: vertical-rl; }
body { margin: 0; font-family: serif; line-height: 1.75; }
p { margin: 0; }
h2, h3 { font-weight: bold; margin: 0 0 0 2em; }
h2 { font-size: 1.3em; }
h3 { font-size: 1.1em; }
.colophon p { font-size: 0.85em; }
.cover { margin: 0; padding: 0; text-align: center; writing-mode: horizontal-tb; }
.cover img { max-width: 100%; max-height: 100vh; }
''';

String _xhtml(String title, String body, {String bodyClass = ''}) =>
    '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="ja" lang="ja">
<head>
<meta charset="UTF-8"/>
<title>${escapeXml(title)}</title>
<link rel="stylesheet" type="text/css" href="../style.css"/>
</head>
<body${bodyClass.isEmpty ? '' : ' class="$bodyClass"'}>
$body
</body>
</html>
''';

/// 按 [maxChars] 截取开头若干章（至少一章；单章超长时在段落边界截断）。
List<AozoraChapter> selectChapters(List<AozoraChapter> all, int maxChars) {
  final List<AozoraChapter> picked = <AozoraChapter>[];
  int total = 0;
  for (final AozoraChapter c in all) {
    if (picked.isNotEmpty && total + c.plainChars > maxChars) break;
    if (c.plainChars > maxChars - total) {
      final AozoraChapter cut = AozoraChapter()
        ..headingLabels.addAll(c.headingLabels);
      for (final String block in c.blocksHtml) {
        if (cut.plainChars >= maxChars - total) break;
        cut.blocksHtml.add(block);
        if (block.startsWith('<p>')) {
          cut.paragraphCount++;
          cut.plainChars += _plainText(block).length;
        }
      }
      picked.add(cut);
      break;
    }
    picked.add(c);
    total += c.plainChars;
  }
  return picked;
}

Uint8List buildEpub({
  required String id,
  required String title,
  required String author,
  required AozoraDoc doc,
  required int maxChars,
  required Uint8List coverJpeg,
  required String sourcePage,
  required String coverCredit,
  required String coverSourcePage,
}) {
  final List<AozoraChapter> chapters = selectChapters(doc.chapters, maxChars);
  if (chapters.isEmpty) throw FixtureError('$id: 正文解析为空');
  final bool truncated =
      chapters.length < doc.chapters.length ||
      chapters.last.blocksHtml.length <
          doc.chapters[chapters.length - 1].blocksHtml.length;

  final Archive zip = Archive();
  final ArchiveFile mimetype = ArchiveFile.noCompress(
    'mimetype',
    20,
    utf8.encode('application/epub+zip'),
  );
  zip.addFile(mimetype);
  zip.addFile(
    _textFile('META-INF/container.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
'''),
  );
  zip.addFile(_textFile('OEBPS/style.css', _css));
  zip.addFile(
    ArchiveFile.noCompress(
      'OEBPS/images/cover.jpg',
      coverJpeg.length,
      coverJpeg,
    ),
  );
  zip.addFile(
    _textFile(
      'OEBPS/text/cover.xhtml',
      _xhtml(
        title,
        '<section class="cover" epub:type="cover"><img src="../images/cover.jpg" alt="${escapeXml(title)}"/></section>',
        bodyClass: 'cover',
      ),
    ),
  );

  final List<String> chapterFiles = <String>[];
  final List<String> navItems = <String>[];
  for (int i = 0; i < chapters.length; i++) {
    final AozoraChapter c = chapters[i];
    final String name = 'ch${(i + 1).toString().padLeft(3, '0')}.xhtml';
    chapterFiles.add(name);
    final StringBuffer body = StringBuffer();
    if (i == 0) {
      body.writeln('<h2>${escapeXml(title)}</h2>');
      body.writeln('<p>${escapeXml(author)}</p>');
    }
    for (final String block in c.blocksHtml) {
      body.writeln(block);
    }
    final String label = c.headingLabels.isEmpty
        ? title
        : c.headingLabels.join(' ');
    navItems.add('<li><a href="text/$name">${escapeXml(label)}</a></li>');
    zip.addFile(_textFile('OEBPS/text/$name', _xhtml(title, body.toString())));
  }

  final StringBuffer colophon = StringBuffer()..writeln('<h3>底本・クレジット</h3>');
  for (final String l in doc.colophon) {
    colophon.writeln('<p>${aozoraInlineToXhtml(l)}</p>');
  }
  colophon
    ..writeln('<p>　</p>')
    ..writeln(
      truncated
          ? '<p>※ この EPUB は Fushi のテスト素材として冒頭部分のみを収録した抜粋です。全文は青空文庫：${escapeXml(sourcePage)}</p>'
          : '<p>※ 青空文庫：${escapeXml(sourcePage)}</p>',
    )
    ..writeln(
      '<p>表紙：${escapeXml(coverCredit)}（${escapeXml(coverSourcePage)}）</p>',
    );
  zip.addFile(
    _textFile(
      'OEBPS/text/colophon.xhtml',
      _xhtml(title, colophon.toString(), bodyClass: 'colophon'),
    ),
  );
  navItems.add('<li><a href="text/colophon.xhtml">底本・クレジット</a></li>');

  zip.addFile(
    _textFile('OEBPS/nav.xhtml', '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="ja" lang="ja">
<head><meta charset="UTF-8"/><title>目次</title></head>
<body>
<nav epub:type="toc" id="toc"><h1>目次</h1>
<ol>
${navItems.join('\n')}
</ol>
</nav>
</body>
</html>
'''),
  );

  final String manifestItems = <String>[
    '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
    '<item id="css" href="style.css" media-type="text/css"/>',
    '<item id="cover-image" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>',
    '<item id="cover" href="text/cover.xhtml" media-type="application/xhtml+xml"/>',
    for (int i = 0; i < chapterFiles.length; i++)
      '<item id="c${i + 1}" href="text/${chapterFiles[i]}" media-type="application/xhtml+xml"/>',
    '<item id="colophon" href="text/colophon.xhtml" media-type="application/xhtml+xml"/>',
  ].join('\n    ');
  final String spine = <String>[
    '<itemref idref="cover"/>',
    for (int i = 0; i < chapterFiles.length; i++)
      '<itemref idref="c${i + 1}"/>',
    '<itemref idref="colophon"/>',
  ].join('\n    ');
  zip.addFile(
    _textFile('OEBPS/content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="ja">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">urn:fushi-fixture:$id</dc:identifier>
    <dc:title>${escapeXml(title)}</dc:title>
    <dc:creator>${escapeXml(author)}</dc:creator>
    <dc:language>ja</dc:language>
    <dc:source>${escapeXml(sourcePage)}</dc:source>
    <dc:rights>Public domain text from Aozora Bunko. Cover: ${escapeXml(coverCredit)}</dc:rights>
    <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
    <meta name="cover" content="cover-image"/>
  </metadata>
  <manifest>
    $manifestItems
  </manifest>
  <spine page-progression-direction="rtl">
    $spine
  </spine>
</package>
'''),
  );
  return _zip(zip);
}

ArchiveFile _textFile(String name, String content) {
  final List<int> bytes = utf8.encode(content);
  return ArchiveFile(name, bytes.length, bytes);
}

/// 固定时间戳编码，让同样输入产出同样字节。
Uint8List _zip(Archive a) {
  for (final ArchiveFile f in a.files) {
    f.lastModTime = DateTime.utc(2026).millisecondsSinceEpoch ~/ 1000;
  }
  final List<int>? bytes = ZipEncoder().encode(
    a,
    level: Deflate.BEST_COMPRESSION,
    modified: DateTime.utc(2026),
  );
  if (bytes == null) throw FixtureError('zip 编码失败');
  return Uint8List.fromList(bytes);
}

// ---------------------------------------------------------------------------
// 汇总产物
// ---------------------------------------------------------------------------

void writeLibraryJson(String outDir, List<ItemOutcome> outcomes) {
  List<Map<String, String>> of(String kind) => outcomes
      .where((ItemOutcome o) => o.kind == kind && o.entry != null)
      .map((ItemOutcome o) => o.entry!)
      .toList();
  final Map<String, Object> lib = <String, Object>{
    'books': of('book'),
    'videos': of('video'),
    'manga': of('manga'),
    'games': of('game'),
  };
  File(
    p.join(outDir, 'library.json'),
  ).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(lib)}\n');
}

void writeAttribution(
  String outDir,
  List<Map<String, dynamic>> items,
  List<ItemOutcome> outcomes,
) {
  final Set<String> ok = outcomes
      .where((ItemOutcome o) => o.entry != null)
      .map((ItemOutcome o) => o.id)
      .toSet();
  final StringBuffer b = StringBuffer()
    ..writeln('Fushi site preview library fixtures — attribution')
    ..writeln('');
  for (final Map<String, dynamic> it in items) {
    if (!ok.contains(it['id'])) continue;
    final Map<String, dynamic> lic = it['license'] as Map<String, dynamic>;
    b
      ..writeln('[${it['kind']}] ${it['title']}')
      ..writeln('  ${it['attribution']}')
      ..writeln('  License: ${lic['name']}  ${lic['url']}')
      ..writeln('  Source: ${it['sourcePage']}');
    for (final String key in <String>['cover', 'clip']) {
      final Map<String, dynamic>? a = it[key] as Map<String, dynamic>?;
      if (a == null) continue;
      b.writeln(
        '  $key: ${a['attribution']} — ${a['license']} — ${a['sourcePage']}',
      );
    }
    b.writeln('');
  }
  File(p.join(outDir, 'ATTRIBUTION.txt')).writeAsStringSync(b.toString());
}

int dirSize(String dir, {required bool excludeDownloads}) {
  int total = 0;
  final String downloads = p.join(dir, '_downloads');
  for (final FileSystemEntity e in Directory(dir).listSync(recursive: true)) {
    if (e is! File) continue;
    if (excludeDownloads && p.isWithin(downloads, e.path)) continue;
    total += e.lengthSync();
  }
  return total;
}

String formatBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KiB';
  return '${(n / 1024 / 1024).toStringAsFixed(2)} MiB';
}
