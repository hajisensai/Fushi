/// `ctl downloads add`：磁链或 .torrent（本地文件 / http(s) 地址）投进 host 的下载管线，
/// 可只下其中几个文件、带上年份与作品身份（入库后按这个身份直接刮削）。
///
/// .torrent 由 CLI 自己下载 + 解析（引擎的 [inspectTorrentMetainfo]，与 app「添加任务」
/// 对话框同一个解析器），文件下标与下载后端同域；`--list-files` 只列清单不投递。
/// 投递走 `POST /api/admin/downloads`（admin 模式）或互联 `POST /api/downloads`
/// （`--interconnect` 模式），两边是同一份请求解析（`HostDownloadAddRequest.fromJson`）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:fushi_engine/media/torrent/torrent_metainfo.dart';
import 'package:fushi_engine/utils/net/app_http.dart' show createAppHttpClient;
import 'package:fushi_server/src/ctl/admin_client.dart';

/// 往 `ctl` 参数表里补 `downloads add` 用到的选项。
void addCtlDownloadOptions(ArgParser parser) {
  parser
    ..addOption('magnet', help: 'downloads add：磁链（也可作位置参数）')
    ..addOption('torrent', help: 'downloads add：.torrent 本地路径或 http(s) 地址（下载走 HTTPS_PROXY）')
    ..addMultiOption(
      'select',
      splitCommas: false,
      help: 'downloads add：只下文件路径匹配该正则的文件（不区分大小写，可重复）',
    )
    ..addMultiOption('index', help: 'downloads add：只下这个文件下标（可重复，见 --list-files）')
    ..addFlag('list-files', negatable: false, help: 'downloads add：只列出 .torrent 的文件清单（下标 / 大小 / 路径）')
    ..addOption('year', help: 'downloads add：作品年份')
    ..addOption('subtitle-policy', help: 'downloads add：none | bestEffort | required');
}

/// .torrent 的来源：本地路径或 http(s) 地址。
typedef CtlTorrentFetcher = Future<Uint8List> Function(Uri url);

/// `ctl downloads add`。退出码：0 成功；64 用法错误；65 .torrent 解析失败；
/// 66 本地文件不存在；69 下载 .torrent 失败；其余按 [exitCodeFor]。
Future<int> runCtlDownloadAdd(
  AdminClient client,
  ArgResults command, {
  required StringSink out,
  required StringSink err,
  required int Function(AdminApiException ex) exitCodeFor,
  CtlTorrentFetcher? fetch,
}) async {
  const String usage =
      '用法: fushi_server ctl downloads add --title <标题> (<magnet> | --magnet <m> | --torrent <路径|URL>)\n'
      '        [--select <正则>]... [--index <n>]... [--year <y>] [--provider anidb|mal|tmdb --external-id <id>]\n'
      '        [--media-kind movie|tv] [--subtitle-policy none|bestEffort|required]\n'
      '      fushi_server ctl downloads add --torrent <路径|URL> --list-files';
  final List<String> rest = command.rest;
  final List<String> args = rest.length > 2 ? rest.sublist(2) : const <String>[];
  final String? magnet = _nonEmpty(command['magnet'] as String?) ?? (args.isEmpty ? null : args.first);
  final String? torrent = _nonEmpty(command['torrent'] as String?);
  final List<String> patterns = command['select'] as List<String>;
  final List<String> indexTexts = command['index'] as List<String>;
  final bool listFiles = command['list-files'] as bool;
  if ((magnet == null) == (torrent == null)) {
    err.writeln(usage);
    return 64;
  }
  if (torrent == null && (listFiles || patterns.isNotEmpty || indexTexts.isNotEmpty)) {
    err.writeln('磁链没有文件清单：--list-files / --select / --index 需要 --torrent');
    return 64;
  }

  InspectedTorrentMetainfo? meta;
  if (torrent != null) {
    final Uint8List bytes;
    try {
      bytes = await loadCtlTorrent(torrent, fetch: fetch);
    } on FileSystemException catch (e) {
      err.writeln('读不到 .torrent: ${e.path ?? torrent} ${e.message}');
      return 66;
    } on HttpException catch (e) {
      err.writeln('下载 .torrent 失败: ${e.message}');
      return 69;
    } on SocketException catch (e) {
      err.writeln('下载 .torrent 失败（网络 / 代理？）: ${e.message}');
      return 69;
    } on TimeoutException {
      err.writeln('下载 .torrent 超时: $torrent');
      return 69;
    }
    try {
      meta = inspectTorrentMetainfo(bytes);
    } on TorrentMetainfoException catch (e) {
      err.writeln('不是有效的 .torrent: ${e.message}');
      return 65;
    }
  }
  if (listFiles) {
    _renderFileList(meta!, out, json: command['json'] as bool);
    return 0;
  }

  final String? title = _nonEmpty(command['title'] as String?);
  if (title == null) {
    err.writeln(usage);
    return 64;
  }
  Set<int>? selection;
  if (patterns.isNotEmpty || indexTexts.isNotEmpty) {
    try {
      selection = selectTorrentFiles(meta!.files, patterns: patterns, indexes: indexTexts);
    } on FormatException catch (e) {
      err.writeln(e.message);
      return 64;
    }
  }
  final String? yearText = _nonEmpty(command['year'] as String?);
  final int? year = yearText == null ? null : int.tryParse(yearText);
  if (yearText != null && year == null) {
    err.writeln('--year 要是整数: $yearText');
    return 64;
  }
  final String? provider = _nonEmpty(command['provider'] as String?);
  final String? externalId = _nonEmpty(command['external-id'] as String?);
  if ((provider == null) != (externalId == null)) {
    err.writeln('--provider 与 --external-id 要一起给');
    return 64;
  }
  final String mediaKind = command['media-kind'] as String;
  final Map<String, Object?> body = <String, Object?>{
    if (magnet != null) 'magnet': magnet,
    if (meta != null) 'torrent': base64Encode(meta.bytes),
    'title': title,
    'mediaKind': mediaKind,
    if (selection != null) 'files': (selection.toList()..sort()),
    if (year != null) 'year': year,
    if (provider != null) 'metadataProvider': provider,
    if (externalId != null) 'externalId': externalId,
    if (_nonEmpty(command['subtitle-policy'] as String?) case final String policy) 'subtitlePolicy': policy,
  };
  final Object? response;
  try {
    response = await client.post('/api/admin/downloads', body: body);
  } on AdminApiException catch (ex) {
    err.writeln('POST downloads 失败: $ex');
    if (command['json'] as bool && ex.body != null) out.writeln(_pretty(ex.body));
    return exitCodeFor(ex);
  }
  if (command['json'] as bool) {
    out.writeln(_pretty(response));
    return 0;
  }
  final Object? jobId = response is Map ? response['jobId'] : null;
  out.writeln('jobId: ${jobId ?? '-'}');
  if (meta != null && selection != null) {
    for (final InspectedTorrentFile file in meta.files) {
      if (selection.contains(file.index)) out.writeln('  [${file.index}] ${file.path}');
    }
  }
  return 0;
}

/// 读 .torrent：http(s) 地址经 [fetch]（缺省 [fetchCtlTorrent]），否则当本地路径。
Future<Uint8List> loadCtlTorrent(String source, {CtlTorrentFetcher? fetch}) async {
  final Uri? uri = Uri.tryParse(source);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty) {
    return (fetch ?? fetchCtlTorrent)(uri);
  }
  final File file = File(source);
  final int length = await file.length();
  if (length > kMaximumTorrentMetainfoBytes) {
    throw FileSystemException('file is larger than ${kMaximumTorrentMetainfoBytes ~/ 1024 ~/ 1024} MiB', source);
  }
  return file.readAsBytes();
}

/// 下载一个 .torrent。走应用统一出口 [createAppHttpClient]（含 `HTTPS_PROXY` / `HTTP_PROXY`），
/// 体积上限与解析器同一个 [kMaximumTorrentMetainfoBytes]。非 200 抛 [HttpException]。
Future<Uint8List> fetchCtlTorrent(Uri url, {Duration timeout = const Duration(seconds: 60)}) async {
  // 应用统一出口：环境变量 / 手填代理都由 resolveAppProxyDirective 决定（回环与局域网恒直连）。
  final HttpClient http = createAppHttpClient(connectionTimeout: timeout);
  try {
    final HttpClientRequest request = await http.getUrl(url).timeout(timeout);
    request.headers.set(HttpHeaders.acceptHeader, 'application/x-bittorrent, */*');
    final HttpClientResponse response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException('HTTP ${response.statusCode} ${response.reasonPhrase}', uri: url);
    }
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in response.timeout(timeout)) {
      builder.add(chunk);
      if (builder.length > kMaximumTorrentMetainfoBytes) {
        throw HttpException('response is larger than a .torrent can be', uri: url);
      }
    }
    return builder.takeBytes();
  } finally {
    http.close(force: true);
  }
}

/// `--select`（正则，不区分大小写，匹配文件路径）与 `--index`（下标）的并集。
///
/// 正则写错、下标不是数字 / 越界、什么都没选中都抛 [FormatException]（用法错误）——
/// 选空了照样投递等于整颗下载，正是用户想避免的。
Set<int> selectTorrentFiles(
  List<InspectedTorrentFile> files, {
  List<String> patterns = const <String>[],
  List<String> indexes = const <String>[],
}) {
  if (files.isEmpty) {
    throw const FormatException('这个 .torrent 没有稳定的文件下标（纯 v2），只能整颗下载');
  }
  final Set<int> selected = <int>{};
  for (final String text in indexes) {
    final int? index = int.tryParse(text.trim());
    if (index == null || index < 0 || index >= files.length) {
      throw FormatException('--index $text 越界（0..${files.length - 1}）');
    }
    selected.add(index);
  }
  for (final String pattern in patterns) {
    final RegExp re;
    try {
      re = RegExp(pattern, caseSensitive: false);
    } on FormatException catch (e) {
      throw FormatException('--select 正则无效: $pattern（${e.message}）');
    }
    final Iterable<InspectedTorrentFile> hits = files.where((InspectedTorrentFile f) => re.hasMatch(f.path));
    if (hits.isEmpty) throw FormatException('--select $pattern 没有匹配任何文件（--list-files 看清单）');
    selected.addAll(hits.map((InspectedTorrentFile f) => f.index));
  }
  if (selected.isEmpty) throw const FormatException('没有选中任何文件');
  return selected;
}

void _renderFileList(InspectedTorrentMetainfo meta, StringSink out, {required bool json}) {
  if (json) {
    out.writeln(
      _pretty(<String, Object?>{
        'name': meta.suggestedName,
        'infoHash': meta.torrentId,
        'files': <Object?>[
          for (final InspectedTorrentFile f in meta.files)
            <String, Object?>{'index': f.index, 'size': f.length, 'path': f.path},
        ],
      }),
    );
    return;
  }
  out.writeln('${meta.suggestedName ?? '-'}  (${meta.torrentId})');
  if (meta.files.isEmpty) {
    out.writeln('  （纯 v2 torrent：没有稳定的文件下标，只能整颗下载）');
    return;
  }
  final int width = '${meta.files.length - 1}'.length;
  for (final InspectedTorrentFile f in meta.files) {
    out.writeln('  ${'${f.index}'.padLeft(width)}  ${formatCtlBytes(f.length).padLeft(9)}  ${f.path}');
  }
}

/// 人读的体积（1024 进制，一位小数）。
String formatCtlBytes(int bytes) {
  const List<String> units = <String>['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  double value = bytes.toDouble();
  int unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return unit == 0 ? '$bytes B' : '${value.toStringAsFixed(1)} ${units[unit]}';
}

String _pretty(Object? value) => const JsonEncoder.withIndent('  ').convert(value);

String? _nonEmpty(String? value) {
  final String? v = value?.trim();
  return v == null || v.isEmpty ? null : v;
}
