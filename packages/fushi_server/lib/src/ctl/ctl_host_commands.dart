/// `ctl` 里经 admin 代理（`/api/admin/host/*`）调用互联接口的动作。
///
/// 互联的库 / 刮削 / 进度 / 任务接口原本只对已配对 peer 开放；admin API 以 host
/// 身份进程内代调（见 admin_api.dart `_hostProxy`），这里把常用的几组包成命令，
/// 其余用 `ctl host <METHOD> <path>` 直调。路径一律是互联路径去掉 `/api/` 前缀。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:fushi_server/src/ctl/admin_client.dart';

/// admin 代理前缀。
const String kHostProxy = '/api/admin/host';

/// 一个经代理的单请求动作。
class CtlHostRequest {
  const CtlHostRequest(this.method, this.path, {this.body, this.query, this.listKey});

  final String method;

  /// 已含 [kHostProxy] 前缀的完整 admin 路径。
  final String path;
  final Object? body;
  final Map<String, String>? query;

  /// 响应是列表（或 `{listKey: [...]}`）时用于一行一条渲染；null 表示按通用规则输出。
  final String? listKey;
}

/// 本文件负责的顶层动作名（`ctl_commands.dart` 据此转交）。
const Set<String> kCtlHostActions = <String>{
  'host',
  'books',
  'videos',
  'audiobooks',
  'manga',
  'dict',
  'metadata',
  'scrape',
  'activity',
  'collections',
  'tags',
  'tombstones',
  'assistant',
};

/// 往 `ctl` 参数表里补本文件用到的选项。
void addCtlHostOptions(ArgParser parser) {
  parser
    ..addOption('set', help: 'progress / position / delay / playback：写入的 JSON（不给则读取）')
    ..addOption('query', abbr: 'q', help: 'scrape search：搜索词')
    ..addOption('collection', help: 'scrape：按合集定位作品（合集名）')
    ..addOption('collection-type', help: 'scrape：合集类型（配合 --collection）')
    ..addOption('provider', help: 'scrape identify：anidb | mal | tmdb')
    ..addOption('external-id', help: 'scrape identify：该来源的作品 id')
    ..addOption('episode-group', help: 'scrape identify / episode-group：TMDB 分集排序 id')
    ..addOption('feature', help: 'assistant start：功能名')
    ..addOption('locale', help: 'assistant start：界面语言', defaultsTo: 'zh-CN')
    ..addOption('after', help: 'assistant show：只要比这个 revision 新的视图')
    ..addFlag('wait', negatable: false, help: 'assistant show：长轮询等新视图；jobs submit：等任务结束')
    ..addOption('language', abbr: 'l', help: 'jobs submit asr：语言 tag', defaultsTo: 'ja')
    ..addOption('out', abbr: 'o', help: 'jobs submit / result：产物写到这里');
}

/// 用法说明片段。
const String kCtlHostUsage = '''
  ── 经互联接口（admin 代理）──
  books [ls] | progress <bookKey> [--set '<json>']
  videos [ls] | rm <id> | position|playback <id> [--set '<json>']
  audiobooks [ls] | position|delay <key> [--set '<json>']
  manga manifest <bookKey>
  dict [ls]
  metadata [ls]
  scrape search <bookUid> -q <词> | identify <bookUid> --provider anidb|mal|tmdb --external-id <id>
         [--media-kind tv|movie] [--episode-group g] | episode-groups <bookUid>
         | episode-group <bookUid> --episode-group <g>      （合集作品用 --collection 名 --collection-type 类型）
         | pending | sweep（补刮从未识别的作品） | ai-identify <pending id>
  activity | collections | tags | tombstones
  jobs submit asr <音频> [-l ja] [-o x.srt] [--wait] | get <id> | result <id> [产物名] [-o 文件]
  assistant start --feature <f> | show <id> [--after n] [--wait] | act <id> '<json>' | stop <id>
  host <GET|POST|PUT|DELETE> <互联路径，如 library/books> ['<json>']   直调任意互联接口''';

/// 把一个代理动作翻成请求；用法不对写 [err] 返回 null。
CtlHostRequest? parseCtlHostAction(List<String> rest, ArgResults command, StringSink err) {
  final String action = rest.first;
  final String sub = rest.length > 1 ? rest[1] : '';
  final List<String> args = rest.length > 2 ? rest.sublist(2) : const <String>[];
  String? arg(int i) => i < args.length ? args[i] : null;
  String seg(String v) => Uri.encodeComponent(v);

  CtlHostRequest? usage(String text) {
    err.writeln('用法: fushi_server ctl $text');
    return null;
  }

  /// `--set` 给了 → PUT 该 JSON；没给 → GET。
  CtlHostRequest? readOrWrite(String path) {
    final String? set = command['set'] as String?;
    if (set == null) return CtlHostRequest('GET', '$kHostProxy/$path');
    final Object? body = _jsonObject(set, err);
    return body == null ? null : CtlHostRequest('PUT', '$kHostProxy/$path', body: body);
  }

  switch (action) {
    case 'books':
      switch (sub) {
        case '' || 'ls':
          return const CtlHostRequest('GET', '$kHostProxy/library/books', listKey: '');
        case 'progress' when arg(0) != null:
          return readOrWrite('library/books/${seg(arg(0)!)}/progress');
      }
      return usage("books [ls] | books progress <bookKey> [--set '<json>']");

    case 'videos':
      switch (sub) {
        case '' || 'ls':
          return const CtlHostRequest('GET', '$kHostProxy/library/videos', listKey: '');
        case 'rm' when arg(0) != null:
          return CtlHostRequest('DELETE', '$kHostProxy/library/videos/${seg(arg(0)!)}');
        case 'position' || 'playback' when arg(0) != null:
          return readOrWrite('library/videos/${seg(arg(0)!)}/$sub');
      }
      return usage("videos [ls] | videos rm <id> | videos position|playback <id> [--set '<json>']");

    case 'audiobooks':
      switch (sub) {
        case '' || 'ls':
          return const CtlHostRequest('GET', '$kHostProxy/library/audiobooks', listKey: '');
        case 'position' || 'delay' when arg(0) != null:
          return readOrWrite('library/audiobooks/${seg(arg(0)!)}/$sub');
      }
      return usage("audiobooks [ls] | audiobooks position|delay <key> [--set '<json>']");

    case 'manga':
      if (sub == 'manifest' && arg(0) != null) {
        return CtlHostRequest('GET', '$kHostProxy/library/manga/${seg(arg(0)!)}/manifest');
      }
      return usage('manga manifest <bookKey>');

    case 'dict':
      if (sub == '' || sub == 'ls') {
        return const CtlHostRequest('GET', '$kHostProxy/library/dictionaries', listKey: '');
      }
      return usage('dict [ls]');

    case 'metadata':
      if (sub == '' || sub == 'ls') return const CtlHostRequest('GET', '$kHostProxy/library/metadata');
      return usage('metadata [ls]');

    case 'activity' || 'collections' || 'tags' || 'tombstones':
      return CtlHostRequest('GET', action == 'tombstones' ? '$kHostProxy/tombstones' : '$kHostProxy/library/$action');

    case 'scrape':
      if (sub == 'pending') return const CtlHostRequest('GET', '/api/admin/scrape/pending', listKey: 'works');
      if (sub == 'sweep') return const CtlHostRequest('POST', '/api/admin/scrape/sweep');
      if (sub == 'ai-identify') {
        if (arg(0) == null) return usage('scrape ai-identify <待确认作品 id（scrape pending 的第一列）>');
        return CtlHostRequest('POST', '/api/admin/scrape/ai-identify', body: <String, Object?>{'id': arg(0)});
      }
      final Map<String, Object?>? key = _workKey(arg(0), command);
      switch (sub) {
        case 'search' when key != null:
          final String? query = command['query'] as String?;
          if (query == null || query.trim().isEmpty) return usage('scrape search <bookUid> -q <搜索词>');
          return CtlHostRequest(
            'POST',
            '$kHostProxy/library/metadata/candidates',
            body: <String, Object?>{'key': key, 'query': query.trim()},
            listKey: 'candidates',
          );
        case 'identify' when key != null:
          final String? provider = command['provider'] as String?;
          final String? externalId = command['external-id'] as String?;
          // `--media-kind` 与 downloads add 共用（那边缺省 movie）；刮削动画缺省按 tv。
          final String mediaKind = command.wasParsed('media-kind') ? command['media-kind'] as String : 'tv';
          if (provider == null || externalId == null || !const <String>{'tv', 'movie'}.contains(mediaKind)) {
            return usage(
              'scrape identify <bookUid> --provider anidb|mal|tmdb --external-id <id> [--media-kind tv|movie]',
            );
          }
          return CtlHostRequest(
            'POST',
            '$kHostProxy/library/metadata/scrape',
            body: <String, Object?>{
              'key': key,
              'lookup': <String, Object?>{
                'provider': provider,
                'externalId': externalId,
                'mediaKind': mediaKind,
                if (command['episode-group'] != null) 'episodeGroupId': command['episode-group'] as String,
              },
            },
          );
        case 'episode-groups' when key != null:
          return CtlHostRequest(
            'POST',
            '$kHostProxy/library/metadata/episode-groups',
            body: <String, Object?>{'key': key},
          );
        case 'episode-group' when key != null && command['episode-group'] != null:
          return CtlHostRequest(
            'POST',
            '$kHostProxy/library/metadata/episode-group',
            body: <String, Object?>{'key': key, 'episodeGroupId': command['episode-group'] as String},
          );
      }
      return usage(
        'scrape pending | scrape search <bookUid> -q <词> | scrape identify <bookUid> --provider p --external-id id '
        '| scrape episode-groups <bookUid> | scrape episode-group <bookUid> --episode-group g',
      );

    case 'assistant':
      switch (sub) {
        case 'start':
          final String? feature = command['feature'] as String?;
          if (feature == null || feature.trim().isEmpty) return usage('assistant start --feature <功能名>');
          return CtlHostRequest(
            'POST',
            '$kHostProxy/assistant/sessions',
            body: <String, Object?>{'feature': feature.trim(), 'locale': command['locale'] as String},
          );
        case 'show' when arg(0) != null:
          return CtlHostRequest(
            'GET',
            '$kHostProxy/assistant/sessions/${seg(arg(0)!)}',
            query: <String, String>{
              if (command['after'] != null) 'after': command['after'] as String,
              if (command['wait'] as bool) 'wait': '1',
            },
          );
        case 'act' when arg(0) != null && arg(1) != null:
          final Object? body = _jsonObject(arg(1)!, err);
          return body == null
              ? null
              : CtlHostRequest('POST', '$kHostProxy/assistant/sessions/${seg(arg(0)!)}/actions', body: body);
        case 'stop' when arg(0) != null:
          return CtlHostRequest('DELETE', '$kHostProxy/assistant/sessions/${seg(arg(0)!)}');
      }
      return usage("assistant start --feature f | show <id> [--after n] [--wait] | act <id> '<json>' | stop <id>");

    case 'host':
      final String method = sub.toUpperCase();
      final String? raw = arg(0);
      if (!const <String>{'GET', 'POST', 'PUT', 'DELETE'}.contains(method) || raw == null) {
        return usage("host <GET|POST|PUT|DELETE> <互联路径> ['<json>']");
      }
      final Uri parsed = Uri.parse(raw.replaceFirst(RegExp(r'^/?(api/)?'), ''));
      Object? body;
      if (arg(1) != null) {
        body = _jsonObject(arg(1)!, err);
        if (body == null) return null;
      }
      return CtlHostRequest(
        method,
        '$kHostProxy/${parsed.path}',
        body: body,
        query: parsed.queryParameters.isEmpty ? null : parsed.queryParameters,
      );
  }
  return usage(kCtlHostUsage);
}

/// `jobs submit|get|result`：互联通用任务协议（host_job_routes.dart），多请求。
///
/// 返回 null 表示不是本函数负责的 jobs 子动作（`jobs ls|rm` 走 admin 自己的接口）。
Future<int>? runCtlJobsAction(
  AdminClient client,
  ArgResults command, {
  required StringSink out,
  required StringSink err,
  required int Function(AdminApiException ex) exitCodeFor,
  Duration pollInterval = const Duration(seconds: 2),
}) {
  final List<String> rest = command.rest;
  final String sub = rest.length > 1 ? rest[1] : '';
  final List<String> args = rest.length > 2 ? rest.sublist(2) : const <String>[];
  switch (sub) {
    case 'submit':
      return _submitJob(client, command, args, out: out, err: err, exitCodeFor: exitCodeFor, poll: pollInterval);
    case 'get' when args.isNotEmpty:
      return _guard(err, exitCodeFor, () async {
        final Object? r = await client.get('$kHostProxy/jobs/${Uri.encodeComponent(args.first)}');
        out.writeln(const JsonEncoder.withIndent('  ').convert(r));
        return 0;
      });
    case 'result' when args.isNotEmpty:
      return _guard(err, exitCodeFor, () async {
        final String name = args.length > 1 ? '/${Uri.encodeComponent(args[1])}' : '';
        final Object? r = await client.get('$kHostProxy/jobs/${Uri.encodeComponent(args.first)}/result$name');
        return _writeResult(r, command['out'] as String?, out);
      });
  }
  return null;
}

Future<int> _submitJob(
  AdminClient client,
  ArgResults command,
  List<String> args, {
  required StringSink out,
  required StringSink err,
  required int Function(AdminApiException ex) exitCodeFor,
  required Duration poll,
}) async {
  if (args.length < 2 || args.first != 'asr') {
    err.writeln('用法: fushi_server ctl jobs submit asr <音频> [-l ja] [-o x.srt] [--wait]');
    return 64;
  }
  final File audio = File(args[1]);
  if (!audio.existsSync()) {
    err.writeln('找不到文件: ${audio.path}');
    return 66;
  }
  return _guard(err, exitCodeFor, () async {
    final Object? created = await client.post(
      '$kHostProxy/jobs',
      body: <String, Object?>{
        'kind': 'asr',
        'params': <String, Object?>{'language': command['language'] as String, 'input': 'audio'},
      },
    );
    final String? id = created is Map ? created['jobId']?.toString() : null;
    if (id == null) throw AdminApiException(1, '服务端没返回 jobId: $created');
    final String base = '$kHostProxy/jobs/${Uri.encodeComponent(id)}';
    err.writeln('任务 $id：上传 ${audio.path}…');
    await client.sendBytes('PUT', '$base/input/audio', bytes: await audio.readAsBytes());
    await client.post('$base/start');
    final bool wait = command['wait'] as bool || command['out'] != null;
    if (!wait) {
      out.writeln(id);
      return 0;
    }
    while (true) {
      final Object? job = await client.get(base);
      final String state = job is Map ? '${job['state']}' : '?';
      final Object? progress = job is Map ? job['progress'] : null;
      err.write('\r$id  $state  ${progress is num ? '${(progress * 100).toStringAsFixed(1)}%' : ''}   ');
      if (state == 'done') {
        err.writeln();
        final Object? result = await client.get('$base/result');
        return _writeResult(result, command['out'] as String?, out);
      }
      if (state == 'error' || state == 'cancelled') {
        err.writeln('\n任务 $state: ${job is Map ? job['error'] ?? job['message'] ?? '' : ''}');
        return 1;
      }
      await Future<void>.delayed(poll);
    }
  });
}

int _writeResult(Object? result, String? outPath, StringSink out) {
  final String text = result is String ? result : const JsonEncoder.withIndent('  ').convert(result);
  if (outPath == null) {
    out.writeln(text);
  } else {
    File(outPath).writeAsStringSync(text);
    out.writeln('已写入 $outPath');
  }
  return 0;
}

Future<int> _guard(StringSink err, int Function(AdminApiException ex) exitCodeFor, Future<int> Function() body) async {
  try {
    return await body();
  } on AdminApiException catch (ex) {
    err.writeln('\n失败: $ex');
    return exitCodeFor(ex);
  }
}

/// 作品定位：位置参数是 bookUid；或 `--collection 名 --collection-type 类型` 指合集作品。
Map<String, Object?>? _workKey(String? bookUid, ArgResults command) {
  final String? collection = command['collection'] as String?;
  if (collection != null) {
    // 服务端的作品键要求 name 与 collectionType 同时给出（VideoMetadataWorkKey.fromJson）。
    final String? type = command['collection-type'] as String?;
    if (type == null) return null;
    return <String, Object?>{
      'collection': <String, Object?>{'name': collection, 'collectionType': type},
    };
  }
  if (bookUid == null || bookUid.isEmpty) return null;
  return <String, Object?>{'bookUid': bookUid};
}

Object? _jsonObject(String text, StringSink err) {
  try {
    final Object? decoded = jsonDecode(text);
    if (decoded is Map) return decoded;
    err.writeln('要求 JSON 对象: $text');
  } on FormatException catch (e) {
    err.writeln('JSON 解析失败: ${e.message}');
  }
  return null;
}
