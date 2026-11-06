// 推荐包分发清单生成器。
//
// 两种形态，对应 `RecommendedPackManifest.toDownloadPlan()` 的两条路：
//
//   range  只算总长 + sha256，产出一份指向**现有整包直链**的清单。服务端零改动、
//          不用重新上传任何东西，客户端立刻获得并发分段 + 断点续传。
//   slice  额外把包切成固定大小的分片文件，可以撒在多台主机上（单片 ≤2 GB 时
//          GitHub Release 也装得下），清单里带每片 sha256。
//
// 用法（在 `fushi/` 下）：
//   dart run tool/make_download_manifest.dart \
//     --input D:\packs\fushi-recommended-2026-08-14.fushi.zip \
//     --whole-url https://fushi.moe/pack/pack-2026-08-14/fushi-recommended.fushi.zip \
//     --mode range --version 2026-08-14
//
//   dart run tool/make_download_manifest.dart \
//     --input ...zip --mode slice --part-size 256MiB --out-dir D:\packs\slices \
//     --whole-url https://fushi.moe/pack/pack-2026-08-14/fushi-recommended.fushi.zip \
//     --part-base-url https://github.com/hajisensai/fushi-pack/releases/download/pack-2026-08-14 \n//     --part-base-url https://fushi.moe/pack/pack-2026-08-14 \
//     --mirror https://fushi.moe/pack/pack-2026-08-14/fushi-recommended.fushi.zip
//
// 切片文件名固定为 `<包名>.NNN`（三位十进制，从 000 起），与清单里的 `name` 对应。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const int _kDefaultPartSize = 64 * 1024 * 1024;
const int _kReadChunk = 1 << 20;

void main(List<String> argv) async {
  final _Args args;
  try {
    args = _Args.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('参数错误：${e.message}\n');
    stderr.writeln(_usage);
    exitCode = 2;
    return;
  }

  final File input = File(args.input);
  if (!input.existsSync()) {
    stderr.writeln('找不到输入文件：${args.input}');
    exitCode = 2;
    return;
  }

  final int totalBytes = input.lengthSync();
  final String packName = _basename(args.input);
  final String? collision = deflatePartNameCollision(
    packName,
    args.deflateManifest,
  );
  if (collision != null) {
    stderr.writeln(collision);
    exitCode = 2;
    return;
  }
  stdout.writeln('输入：$packName（$totalBytes 字节，${_human(totalBytes)}）');
  stdout.writeln('模式：${args.slice ? 'slice（切片）' : 'range（整包 + Range）'}');

  final List<Map<String, Object?>> parts = <Map<String, Object?>>[];
  final Directory? outDir = args.slice ? Directory(args.outDir!) : null;
  if (outDir != null && !outDir.existsSync()) {
    outDir.createSync(recursive: true);
  }

  // 整包摘要边读边算；切片模式下同一遍读顺手把片写出去 + 算片摘要。
  final ByteConversionSink wholeSink = sha256.startChunkedConversion(
    _DigestSink((Digest d) => _whole = d),
  );

  final RandomAccessFile reader = await input.open();
  try {
    int offset = 0;
    int partIndex = 0;
    while (offset < totalBytes) {
      final int partLength = offset + args.partSize > totalBytes
          ? totalBytes - offset
          : args.partSize;
      final String partName =
          '$packName.${partIndex.toString().padLeft(3, '0')}';

      Digest? partDigest;
      final ByteConversionSink partSink = sha256.startChunkedConversion(
        _DigestSink((Digest d) => partDigest = d),
      );

      IOSink? sliceSink;
      if (outDir != null) {
        sliceSink = File(
          '${outDir.path}${Platform.pathSeparator}$partName',
        ).openWrite();
      }

      int remaining = partLength;
      while (remaining > 0) {
        final int want = remaining < _kReadChunk ? remaining : _kReadChunk;
        final Uint8List bytes = await reader.read(want);
        if (bytes.isEmpty) {
          throw StateError('读取提前结束：偏移 ${offset + partLength - remaining}');
        }
        wholeSink.addSlice(bytes, 0, bytes.length, false);
        partSink.addSlice(bytes, 0, bytes.length, false);
        sliceSink?.add(bytes);
        remaining -= bytes.length;
      }
      partSink.close();
      if (sliceSink != null) {
        await sliceSink.flush();
        await sliceSink.close();
      }

      parts.add(<String, Object?>{
        'name': partName,
        'offset': offset,
        'length': partLength,
        'sha256': partDigest.toString(),
      });
      stdout.writeln(
        '  片 ${partIndex.toString().padLeft(3, '0')}  '
        '偏移 $offset  长度 $partLength  ${partDigest.toString().substring(0, 12)}…',
      );

      offset += partLength;
      partIndex += 1;
    }
  } finally {
    await reader.close();
  }
  wholeSink.close();

  final Map<String, Object?> manifest = <String, Object?>{
    'version': args.version,
    'url': args.wholeUrl,
    'sha256': _whole.toString(),
    'size_bytes': totalBytes,
    if (args.mirrors.isNotEmpty) 'mirrors': args.mirrors,
    'part_size_bytes': args.partSize,
    if (args.slice) ...<String, Object?>{
      'part_base_urls': args.partBaseUrls,
      'parts': parts,
    },
    if (args.deflateManifest != null) 'deflate_pack': args.deflateManifest,
  };

  final String outPath =
      args.manifestPath ??
      (args.slice
          ? '${outDir!.path}${Platform.pathSeparator}$packName.manifest.json'
          : '${input.parent.path}${Platform.pathSeparator}$packName.manifest.json');
  File(
    outPath,
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest));

  stdout.writeln('\n整包 sha256：$_whole');
  stdout.writeln('清单写入：$outPath');
  if (args.slice && args.partBaseUrls.isEmpty) {
    stdout.writeln(
      '警告：slice 模式没给 --part-base-url，清单里的切片来源为空，'
      '客户端只会退回整包 Range 模式。',
    );
  }
  stdout.writeln(
    '\n下一步：把清单上传到 kRecommendedPackManifestUrl 指向的地址'
    '${args.slice ? '，并把切片上传到 --part-base-url 指向的目录' : ''}。',
  );
}

late Digest _whole;

class _DigestSink implements Sink<Digest> {
  _DigestSink(this._onDigest);
  final void Function(Digest) _onDigest;
  @override
  void add(Digest data) => _onDigest(data);
  @override
  void close() {}
}

/// 包分片**不能**放主 app 仓库（hajisensai/Fushi）的 release。
///
/// 那个仓库的 `.github/workflows/mirror-releases.yml` 挂在 `release: published`
/// 上且**没有 tag 过滤**，只跳过预发布。一旦在那里发布包 release，它会：
/// ① 把整包（约 9.5 GB）拉进 runner；② 每个分片都超过 MAX_ASSET_MB=300 被跳过上传；
/// ③ 仍然**无条件**把一份资产列表为空的 manifest.json 覆盖写进 R2；
/// ④ 按 KEEP_RELEASES 轮转，删掉上一版 app 的镜像文件。
/// 净结果是 fushi.moe/releases 下载当场失效。
///
/// 所以这里直接拒绝，而不是写进文档指望人记得——包分片放独立仓库 fushi-pack。
/// 将来若给那个 workflow 加了 tag 过滤，改这一个函数即可。
/// 测试入口：驱动**真实**的参数解析路径。
///
/// 只测 [hazardousReleaseHost] 纯函数的话，把 `_Args.parse` 里那两行调用删掉，
/// 纯函数的用例照样全绿——守卫就成了摆设。测试经由这里走真实校验，
/// 调用点一旦消失当场红。
void parseArgsForTest(List<String> argv) => _Args.parse(argv);

String? hazardousReleaseHost(String url) {
  final Uri? parsed = Uri.tryParse(url);
  if (parsed == null) return null;
  if (parsed.host.toLowerCase() != 'github.com') return null;
  final List<String> seg = parsed.pathSegments;
  if (seg.length < 2) return null;
  if (seg[0].toLowerCase() != 'hajisensai') return null;
  if (seg[1].toLowerCase() != 'fushi') return null;
  return '拒绝：$url 指向主 app 仓库的 release。'
      '在那里发布包会触发 mirror-releases.yml，用空资产清单覆盖 R2 的 '
      'manifest.json 并轮转删除上一版镜像，fushi.moe/releases 会当场失效。'
      '请改用独立仓库，例如 https://github.com/hajisensai/fushi-pack/releases/download/<tag>。';
}

class _Args {
  _Args({
    required this.input,
    required this.wholeUrl,
    required this.version,
    required this.partSize,
    required this.slice,
    required this.outDir,
    required this.mirrors,
    required this.partBaseUrls,
    required this.manifestPath,
    required this.deflateManifest,
  });

  final String input;
  final String wholeUrl;
  final String version;
  final int partSize;
  final bool slice;
  final String? outDir;
  final List<String> mirrors;
  final List<String> partBaseUrls;
  final String? manifestPath;

  /// `--deflate-manifest` 读进来的 deflate 包清单，原样嵌进 `deflate_pack` 键
  /// （见 app 侧 `kRecommendedPackDeflateManifestKey`：新版取它，旧版只认顶层）。
  final Map<String, Object?>? deflateManifest;

  static _Args parse(List<String> argv) {
    final Map<String, String> single = <String, String>{};
    final List<String> mirrors = <String>[];
    final List<String> partBaseUrls = <String>[];

    for (int i = 0; i < argv.length; i++) {
      final String flag = argv[i];
      if (!flag.startsWith('--')) {
        throw FormatException('无法识别的参数 $flag');
      }
      if (i + 1 >= argv.length) {
        throw FormatException('$flag 缺少取值');
      }
      final String value = argv[++i];
      switch (flag) {
        case '--mirror':
          mirrors.add(value);
        case '--part-base-url':
          partBaseUrls.add(value);
        default:
          single[flag] = value;
      }
    }

    final String? input = single['--input'];
    if (input == null) throw const FormatException('--input 必填');
    final String? wholeUrl = single['--whole-url'];
    if (wholeUrl == null) throw const FormatException('--whole-url 必填');
    // 所有外发下载地址走同一道门。别再给某一类 URL 开单独分支——
    // wholeUrl 曾经就是单独只查 https、漏掉 hazardousReleaseHost，而它正是
    // 真实下载源（会作为 DownloadSource 挂到每一个分片上），于是
    // `--whole-url https://github.com/hajisensai/fushi/releases/...` 可以完整
    // 绕过守卫——正是守卫想拦的那种事故形态。
    for (final String url in <String>[wholeUrl, ...mirrors, ...partBaseUrls]) {
      if (!url.startsWith('https://')) {
        throw FormatException('下载地址必须是 https：$url');
      }
      final String? hazard = hazardousReleaseHost(url);
      if (hazard != null) throw FormatException(hazard);
    }

    final String mode = single['--mode'] ?? 'slice';
    if (mode != 'slice' && mode != 'range') {
      throw FormatException('--mode 只能是 slice 或 range，实到 $mode');
    }
    final bool slice = mode == 'slice';
    final String? outDir = single['--out-dir'];
    if (slice && outDir == null) {
      throw const FormatException('slice 模式必须给 --out-dir');
    }

    return _Args(
      input: input,
      wholeUrl: wholeUrl,
      version: single['--version'] ?? _basename(input),
      partSize: _parseSize(single['--part-size']) ?? _kDefaultPartSize,
      slice: slice,
      outDir: outDir,
      mirrors: mirrors,
      partBaseUrls: partBaseUrls,
      manifestPath: single['--manifest-out'],
      deflateManifest: _readDeflateManifest(single['--deflate-manifest']),
    );
  }
}

/// 两个包的切片会上传到同一个 release，切片名是 `<包名>.NNN`。deflate 包若与
/// 本包同名，切片会互相覆盖，旧版下到的就是 deflate 字节（sha256 必然对不上，
/// 但白下一整包）。返回错误文案；不撞名返回 null。
String? deflatePartNameCollision(
  String packName,
  Map<String, Object?>? deflateManifest,
) {
  if (deflateManifest == null) return null;
  final Object? parts = deflateManifest['parts'];
  if (parts is! List) return null;
  for (final Object? part in parts) {
    if (part is Map && part['name'] is String) {
      final String name = part['name'] as String;
      if (name.startsWith('$packName.')) {
        return '拒绝：deflate 包切片 $name 与本包 $packName 的切片同名，'
            '上传到同一个 release 会互相覆盖。请给 deflate 包换个文件名'
            '（如 fushi-recommended.deflate.fushi.zip）后重新切片。';
      }
    }
  }
  return null;
}

/// 读 `--deflate-manifest` 指向的清单（本工具对 deflate 包跑一遍的产物）。
///
/// 它会被新版 app 当成真实下载源，所以和顶层地址过同一道门：https + 不得指向
/// 主 app 仓库的 release。嵌套清单自己不能再带 `deflate_pack`，免得套娃。
Map<String, Object?>? _readDeflateManifest(String? path) {
  if (path == null) return null;
  final File file = File(path);
  if (!file.existsSync()) {
    throw FormatException('找不到 --deflate-manifest：$path');
  }
  final Object? decoded = json.decode(file.readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    throw FormatException('--deflate-manifest 不是 JSON 对象：$path');
  }
  if (decoded.containsKey('deflate_pack')) {
    throw FormatException('--deflate-manifest 里不能再嵌 deflate_pack：$path');
  }
  final Object? url = decoded['url'];
  if (url is! String) {
    throw FormatException('--deflate-manifest 缺少 url：$path');
  }
  final List<String> urls = <String>[
    url,
    for (final String key in <String>['mirrors', 'part_base_urls'])
      if (decoded[key] is List)
        for (final Object? item in decoded[key] as List<Object?>)
          if (item is String) item,
  ];
  for (final String u in urls) {
    if (!u.startsWith('https://')) {
      throw FormatException('--deflate-manifest 的下载地址必须是 https：$u');
    }
    final String? hazard = hazardousReleaseHost(u);
    if (hazard != null) throw FormatException(hazard);
  }
  return decoded;
}

/// 支持 `1073741824` / `1GiB` / `64MiB` / `512KiB` 三种写法。
int? _parseSize(String? raw) {
  if (raw == null) return null;
  final RegExpMatch? match = RegExp(
    r'^(\d+)(B|KiB|MiB|GiB)?$',
    caseSensitive: false,
  ).firstMatch(raw);
  if (match == null) {
    throw FormatException('看不懂的大小：$raw');
  }
  final int value = int.parse(match.group(1)!);
  switch (match.group(2)?.toUpperCase()) {
    case 'KIB':
      return value * 1024;
    case 'MIB':
      return value * 1024 * 1024;
    case 'GIB':
      return value * 1024 * 1024 * 1024;
    default:
      return value;
  }
}

String _basename(String path) =>
    path.split(RegExp(r'[\\/]')).where((String s) => s.isNotEmpty).last;

String _human(int bytes) {
  if (bytes >= 1 << 30) {
    return '${(bytes / (1 << 30)).toStringAsFixed(2)} GiB';
  }
  if (bytes >= 1 << 20) {
    return '${(bytes / (1 << 20)).toStringAsFixed(2)} MiB';
  }
  return '$bytes B';
}

const String _usage = '''
用法：dart run tool/make_download_manifest.dart --input <包> --whole-url <https 直链> [选项]

  --input <path>           要分发的包（必填）
  --whole-url <url>        整包直链，写进清单 url 字段（必填，https）
  --mode range|slice       range=只出清单（零重传）；slice=同时切片（默认 slice）
  --out-dir <path>         slice 模式的切片输出目录（slice 必填）
  --part-size <size>       切段大小，支持 64MiB / 1GiB 写法（默认 64MiB）
  --mirror <url>           整包镜像，可重复
  --part-base-url <url>    切片所在目录，可重复（slice 模式）
  --version <str>          包版本标识（默认取输入文件名）
  --manifest-out <path>    清单输出路径（默认与切片/输入同目录）
  --deflate-manifest <path>
                           先对 deflate 包单独跑一遍本工具得到的清单；嵌进本清单的
                           deflate_pack 键（新版 app 下它，旧版只认顶层 STORE 包）。
                           deflate 包文件名必须与 STORE 包不同，否则切片同名互相覆盖
''';
