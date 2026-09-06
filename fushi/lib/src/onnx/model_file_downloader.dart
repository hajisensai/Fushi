/// 与业务无关的模型文件下载器（OCR / ASR 共用）：逐文件字节进度、`.part`
/// 临时名 + 原子 rename、HTTP Range 断点续传、主源失败换镜像、系统代理。
///
/// 事件契约见 [ModelDownloadEvent]：按文件粒度报告 receivedBytes / totalBytes；
/// 全部文件完成后最后发一次 `done=true`；任何失败以 error 事件结束流
/// （async* 抛出即 error）。
///
/// http 栈：`dart:io` [HttpClient] 经 `createAppHttpClient()` 统一装配
/// （BUG-1498：env > GUI 系统代理 > DIRECT），不引新依赖。
///
/// 历史：这套逻辑最初绑着漫画 OCR 的 `MangaOcrModelFile` / `MangaOcrDownloadEvent`
/// 住在 `lib/src/ocr/manga_ocr_model_downloader.dart`；有声书 ASR 接入后抬到本
/// 文件，OCR 那边改成薄适配（类型转换），行为与测试原样保留。
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import 'package:fushi/src/utils/net/app_http.dart';

/// 清单里一个可下载的模型文件（各子系统的清单类型实现本接口）。
abstract interface class DownloadableModelFile {
  /// 落盘文件名（与远端 basename 一致，Range 续传直接复用同 URL）。
  String get fileName;

  /// 主源直链。
  String get url;

  /// 预期字节数（用于 totalBytes 展示与下载后长度校验；0 表示未知、不校验）。
  int get expectedBytes;
}

/// 模型下载进度事件。
class ModelDownloadEvent {
  const ModelDownloadEvent({
    required this.fileName,
    required this.receivedBytes,
    required this.totalBytes,
    this.done = false,
  });

  final String fileName;
  final int receivedBytes;
  final int totalBytes;

  /// 全部文件完成时最后发一次 done=true。
  final bool done;
}

/// 默认进度事件的字节间隔（避免大文件每 chunk 一事件淹没 UI）。
const int kModelDownloadProgressInterval = 512 * 1024;

/// Hugging Face 主源 host。
const String kHuggingFaceHost = 'huggingface.co';

/// Hugging Face 镜像 host（与 huggingface.co **路径完全同构**，只换域名即可命中
/// 同一个 blob）。
///
/// 存在的唯一理由是主源在部分网络下握手就断——几百 MB 的模型对这类用户等于下不
/// 动。镜像只在主源失败后按序尝试（见 [ModelFileDownloader]），不改变默认信任
/// 关系；字节一致性仍由下载器 rename 前的长度校验兜底。
const List<String> kHuggingFaceMirrorHosts = <String>['hf-mirror.com'];

/// 一个 URL 的**下载候选序列**：主源在前，Hugging Face 镜像依次在后。
///
/// 刻意做成从 [url] 派生而不是让清单逐条列出多个 URL：清单里每多一个手写 URL
/// 就多一处能写错的地方，而镜像与主源本就只差 host。非 huggingface.co 的 URL
/// （GitHub release、测试注入的 localhost、将来换源）原样返回单元素列表——没有
/// 「测试专用分支」，只有「不认识的 host 不派生镜像」这一条规则。
List<String> defaultHuggingFaceUrlCandidates(String url) {
  final Uri primary = Uri.parse(url);
  if (primary.host != kHuggingFaceHost) {
    return <String>[url];
  }
  return <String>[
    url,
    for (final String host in kHuggingFaceMirrorHosts)
      primary.replace(host: host).toString(),
  ];
}

List<String> _defaultUrlCandidates(DownloadableModelFile file) =>
    defaultHuggingFaceUrlCandidates(file.url);

/// 模型下载器。[createClient] 可注入（测试指向本地 HttpServer）。
class ModelFileDownloader {
  ModelFileDownloader({
    HttpClient Function()? createClient,
    List<String> Function(DownloadableModelFile file)? urlCandidates,
    this.progressByteInterval = kModelDownloadProgressInterval,
  }) : _createClient = createClient ?? _defaultClient,
       _urlCandidates = urlCandidates ?? _defaultUrlCandidates;

  final HttpClient Function() _createClient;

  /// 单文件的下载候选 URL 序列（主源 + 镜像）。可注入：镜像回退这条分支只有
  /// 把候选序列做成参数才测得到——真实候选写死了 huggingface 域名，测试里的
  /// 本地 HttpServer 永远派生不出第二个候选。
  final List<String> Function(DownloadableModelFile file) _urlCandidates;

  /// 两次进度事件之间至少累积的字节数（首尾事件恒发）。
  final int progressByteInterval;

  // BUG-1498：原先是 `findProxyFromEnvironment`——只读 HTTPS_PROXY/HTTP_PROXY 环境
  // 变量，读不到 Windows 注册表 / macOS / Linux 的 GUI 系统代理。而这条链路要从
  // huggingface 下几百 MB 模型，clash「系统代理」模式（写注册表、不导出 env）下
  // 等于裸直连。改走统一装配点后 env > GUI 系统代理 > DIRECT 一致生效。
  static HttpClient _defaultClient() => createAppHttpClient()
    // 主源在部分网络下是「连不上」而非「连上后慢」。系统默认超时可以拖到
    // 数十秒，多个文件叠起来用户只看到一个不动的进度条。20s 足够覆盖正常
    // 握手，又能让镜像回退在可感知的时间内发生。
    ..connectionTimeout = const Duration(seconds: 20);

  /// 下载清单里所有未就绪文件到 [targetDir]。
  ///
  /// - [isReady] 判定最终文件是否已就绪（各子系统自己的规则，通常是「存在且
  ///   非空」）；已就绪文件跳过（仍发一条 received==total 的完成进度，让 UI
  ///   汇总正确）。
  /// - `.part` 残留触发 Range 续传；服务器不支持（非 206）则整文件重下。
  /// - 单文件完成：长度非零 + （expected>0 时）长度==expected，然后原子
  ///   rename `.part` → 最终名。
  /// - 全部完成后补发 `done=true` 收尾事件。
  Stream<ModelDownloadEvent> downloadAll({
    required List<DownloadableModelFile> files,
    required Directory targetDir,
    required bool Function(File file) isReady,
  }) async* {
    if (files.isEmpty) {
      return;
    }
    await targetDir.create(recursive: true);
    final HttpClient client = _createClient();
    try {
      for (final DownloadableModelFile file in files) {
        final File target = File(p.join(targetDir.path, file.fileName));
        if (isReady(target)) {
          final int size = target.lengthSync();
          yield ModelDownloadEvent(
            fileName: file.fileName,
            receivedBytes: size,
            totalBytes: size,
          );
          continue;
        }
        yield* _downloadFile(client, file, target);
      }
      final DownloadableModelFile last = files.last;
      yield ModelDownloadEvent(
        fileName: last.fileName,
        receivedBytes: last.expectedBytes,
        totalBytes: last.expectedBytes,
        done: true,
      );
    } finally {
      client.close(force: true);
    }
  }

  /// 单文件下载：主源失败按序换镜像（候选序列由 [_urlCandidates] 给出）。
  ///
  /// 换源不清 `.part`——镜像与主源是同一个 blob，续传直接接上；万一遇到内容不
  /// 一致的源，rename 前的长度校验仍会拦下并删掉坏 `.part`。全部候选都失败时抛
  /// 最后一个错误，语义与单源时代一致。
  Stream<ModelDownloadEvent> _downloadFile(
    HttpClient client,
    DownloadableModelFile file,
    File target,
  ) async* {
    final List<String> candidates = _urlCandidates(file);
    Object? lastError;
    StackTrace? lastStack;
    for (final String url in candidates) {
      try {
        // 逐事件转发而不是 `yield*`：async* 里 `yield*` 委托出去的错误直接流向
        // 下游监听者，**不经过**这里的 try/catch——那样写出来的回退循环长得
        // 像模像样，实际第一个候选一失败就整条流报错，永远换不到镜像。
        await for (final ModelDownloadEvent event in _downloadFileFrom(
          client,
          file,
          target,
          url,
        )) {
          yield event;
        }
        return;
      } on Object catch (error, stack) {
        lastError = error;
        lastStack = stack;
      }
    }
    Error.throwWithStackTrace(lastError!, lastStack!);
  }

  Stream<ModelDownloadEvent> _downloadFileFrom(
    HttpClient client,
    DownloadableModelFile file,
    File target,
    String url,
  ) async* {
    final File part = File('${target.path}.part');
    int offset = part.existsSync() ? part.lengthSync() : 0;

    final HttpClientRequest request = await client.getUrl(Uri.parse(url));
    if (offset > 0) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
    }
    final HttpClientResponse response = await request.close();

    if (offset > 0 &&
        response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
        file.expectedBytes > 0 &&
        offset == file.expectedBytes) {
      // `.part` 已经完整（上次在 rename 前中断），服务器对 bytes=<len>- 回 416：
      // 不再拉流，直接走校验 + 原子转正。
      await response.drain<void>();
      yield _finalizePart(file, part, target);
      return;
    }

    final IOSink sink;
    int received;
    int total;
    if (offset > 0 && response.statusCode == HttpStatus.partialContent) {
      // Range 命中：从 offset 续写。
      received = offset;
      total = response.contentLength > 0
          ? offset + response.contentLength
          : math.max(file.expectedBytes, offset);
      sink = part.openWrite(mode: FileMode.append);
    } else if (response.statusCode == HttpStatus.ok) {
      // 服务器不支持 Range（或本就无残留）：整文件重下，截断旧残留。
      received = 0;
      total = response.contentLength > 0
          ? response.contentLength
          : file.expectedBytes;
      sink = part.openWrite();
      offset = 0;
    } else {
      await response.drain<void>();
      throw HttpException(
        'download ${file.fileName} failed: HTTP ${response.statusCode}',
        uri: Uri.parse(url),
      );
    }

    int lastEmitted = -1;
    try {
      yield ModelDownloadEvent(
        fileName: file.fileName,
        receivedBytes: received,
        totalBytes: total,
      );
      lastEmitted = received;
      await for (final List<int> chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (received - lastEmitted >= progressByteInterval) {
          yield ModelDownloadEvent(
            fileName: file.fileName,
            receivedBytes: received,
            totalBytes: total,
          );
          lastEmitted = received;
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    yield _finalizePart(file, part, target);
  }

  /// 完成一个 `.part`：实际大小校验（非零恒查；expected>0 时长度校验——传输
  /// 截断/上游漂移都在 rename 前拦截，绝不把坏档转正）+ 原子 rename，返回该
  /// 文件的完成事件。
  ModelDownloadEvent _finalizePart(
    DownloadableModelFile file,
    File part,
    File target,
  ) {
    final int actual = part.lengthSync();
    if (actual <= 0) {
      throw StateError('download ${file.fileName} produced empty file');
    }
    if (file.expectedBytes > 0 && actual != file.expectedBytes) {
      // 长度不符的 .part 不可信，删掉避免下次 Range 续传在坏偏移上加码。
      try {
        part.deleteSync();
      } catch (_) {}
      throw StateError(
        'download ${file.fileName} size mismatch: '
        'got $actual, expected ${file.expectedBytes}',
      );
    }

    // 原子转正：目标若有非法残留（0 字节）先清掉再 rename。
    if (target.existsSync()) {
      target.deleteSync();
    }
    part.renameSync(target.path);
    return ModelDownloadEvent(
      fileName: file.fileName,
      receivedBytes: actual,
      totalBytes: actual,
    );
  }
}
