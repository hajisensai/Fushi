import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'package:path/path.dart' as path;

import 'dictionary_downloader.dart' show createDictionaryDio;

/// TODO-861③（移植 Hoshi `94d0c41` #59）：词典自动更新的检查周期。`.name` 持久化
/// （daily/weekly/monthly），默认 weekly。每档对应一个 [Duration]。
enum DictionaryUpdateInterval {
  daily(Duration(days: 1)),
  weekly(Duration(days: 7)),
  monthly(Duration(days: 30));

  const DictionaryUpdateInterval(this.duration);

  final Duration duration;

  /// 把持久化的 `.name` 解析回枚举；未知值回退 [weekly]（向后兼容、不崩）。
  static DictionaryUpdateInterval fromName(String? name) {
    for (final DictionaryUpdateInterval i in DictionaryUpdateInterval.values) {
      if (i.name == name) return i;
    }
    return DictionaryUpdateInterval.weekly;
  }
}

/// TODO-861③：纯函数 check-due（移植 Hoshi `autoUpdateDictionaries` 守卫 + 间隔判据）。
/// 返回 true 当且仅当：未在导入/更新（[isBusy] 为 false）、存在可更新词典
/// （[hasUpdatable] 为 true）、且距上次成功更新（[lastUpdate]，null = 从未）已达
/// [interval]。[now] 注入便于测试。无任何副作用。
bool shouldAutoUpdateDictionaries({
  required DateTime now,
  required DateTime? lastUpdate,
  required DictionaryUpdateInterval interval,
  required bool hasUpdatable,
  required bool isBusy,
}) {
  if (isBusy || !hasUpdatable) return false;
  if (lastUpdate == null) return true;
  return now.difference(lastUpdate) >= interval.duration;
}

/// 一轮自动更新是否完整成功。无可更新词典不构成一轮检查；只要有一本远端
/// index 拉取/解析失败，或发现新版后下载重导失败，[completedCount] 就会小于
/// [totalCount]，本轮不应推进下次检查时间，确保下次启动继续重试。
bool didCompleteDictionaryAutoUpdateBatch({
  required int totalCount,
  required int completedCount,
}) {
  return totalCount > 0 && completedCount == totalCount;
}

/// 远端词典 index 的结构化拉取结果。
///
/// 旧的 nullable revision 把「远端与本地 revision 相同」和「断网/坏 JSON」都压成
/// 后续的 `needsUpdate == false`，自动更新因此无法判断一轮检查是否真的成功。
/// [succeeded] 只在拿到非空 revision 时为 true。
final class DictionaryRemoteIndexResult {
  const DictionaryRemoteIndexResult.success(String value)
      : succeeded = true,
        revision = value;

  const DictionaryRemoteIndexResult.failure()
      : succeeded = false,
        revision = null;

  final bool succeeded;
  final String? revision;
}

/// TODO-609：在线 revision 比对手动更新词典——纯 Dart 层（零 C++/FFI/schema）。
///
/// C++ importer 把完整 yomitan index.json（含 revision/isUpdatable/indexUrl/
/// downloadUrl，见 native/.../yomitan_parser.hpp:8 + importer.cpp:1146 的
/// `glz::write_json(index, ...)`）写回 `<resourceDir>/<词典名>/index.json`。本函数
/// 在导入成功后读回该文件，把来源信息提取成 [Dictionary.metadata] 用的弱类型 Map
/// （只填**存在且非空**的字段），从而无需任何 Drift schema 迁移即可持久化来源。
///
/// 健壮性：坏 JSON / 缺文件 / 顶层非对象 → 返回空 Map（绝不抛、不崩）。旧词典或
/// 本地导入词典 metadata 因此为空 → [Dictionary.isUpdatable] 三条件不满足 → 不可更新。
Map<String, String> readSourceMetadataFromIndex(Directory finalDir) {
  final File indexFile = File(path.join(finalDir.path, 'index.json'));
  if (!indexFile.existsSync()) return <String, String>{};

  final dynamic decoded;
  try {
    decoded = jsonDecode(indexFile.readAsStringSync());
  } catch (_) {
    return <String, String>{};
  }
  if (decoded is! Map) return <String, String>{};

  final Map<String, String> out = <String, String>{};

  void putString(String key) {
    final dynamic v = decoded[key];
    if (v is String) {
      final String trimmed = v.trim();
      if (trimmed.isNotEmpty) out[key] = trimmed;
    }
  }

  putString('revision');
  putString('indexUrl');
  putString('downloadUrl');

  // isUpdatable 是 bool；落成字符串 'true'/'false' 与 Dictionary.isUpdatable 的
  // `metadata['isUpdatable'] == 'true'` 判据对齐。缺字段则不落 key。
  final dynamic updatable = decoded['isUpdatable'];
  if (updatable is bool) {
    out['isUpdatable'] = updatable ? 'true' : 'false';
  }

  return out;
}

/// TODO-609：在线更新检查——拉远端 index.json 比 revision。
class DictionaryUpdateService {
  const DictionaryUpdateService();

  /// 本地 [localRevision] 与远端 [remoteRevision] 比对：远端非空且与本地不同 →
  /// 需更新。远端为 null（拉取失败）或空串（远端无 revision）→ 保守返回 false，
  /// 绝不误报「有更新」。
  static bool needsUpdate(String localRevision, String? remoteRevision) {
    if (remoteRevision == null || remoteRevision.isEmpty) return false;
    return remoteRevision != localRevision;
  }

  /// 从远端 index.json 文本里取 revision。坏 JSON / 顶层非对象 / 无 revision /
  /// revision 非字符串或空 → null（纯函数，不抛）。
  static String? parseRevisionFromIndexJson(String body) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final dynamic rev = decoded['revision'];
    if (rev is! String) return null;
    final String trimmed = rev.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// 拉取 [indexUrl] 处的远端 index.json，并区分成功拿到 revision 与网络/解析失败。
  /// [dio] 可注入便于测试。
  static Future<DictionaryRemoteIndexResult> fetchRemoteIndexResult(
    String indexUrl, {
    Dio? dio,
  }) async {
    if (indexUrl.isEmpty) {
      return const DictionaryRemoteIndexResult.failure();
    }
    // BUG-1493：index.json 与词典包同源（github / huggingface），必须走同一套代理 +
    // 超时装配，否则「检查更新」这一步就能在没有代理的直连上无限挂住。
    final Dio client = dio ?? await createDictionaryDio();
    try {
      final Response<String> resp = await client.get<String>(
        indexUrl,
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: true,
          maxRedirects: 5,
        ),
      );
      final String? body = resp.data;
      if (body == null || body.isEmpty) {
        return const DictionaryRemoteIndexResult.failure();
      }
      final String? revision = parseRevisionFromIndexJson(body);
      if (revision == null) {
        return const DictionaryRemoteIndexResult.failure();
      }
      return DictionaryRemoteIndexResult.success(revision);
    } catch (_) {
      return const DictionaryRemoteIndexResult.failure();
    } finally {
      if (dio == null) client.close();
    }
  }

  /// 兼容手动更新调用点的 nullable revision API。自动更新必须使用
  /// [fetchRemoteIndexResult]，否则无法区分“已是最新版”和“检查失败”。
  static Future<String?> fetchRemoteIndex(
    String indexUrl, {
    Dio? dio,
  }) async {
    final DictionaryRemoteIndexResult result =
        await fetchRemoteIndexResult(indexUrl, dio: dio);
    return result.revision;
  }
}
