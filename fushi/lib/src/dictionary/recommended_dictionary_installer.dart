import 'dart:io';

import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi/src/dictionary/dictionary_file_health.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/dictionary_download_controller.dart';
import 'package:fushi/src/models/dictionary_download_resume.dart';
import 'package:fushi/src/models/dictionary_repository.dart';

/// 推荐词典目录条目的安装判据：已装词典里有同 [RecommendedDictionary.matchPrefix] 的
/// （真名等于前缀、去版本后缀的基名等于前缀、或「前缀 + [版本]」形态）。
///
/// 词典管理页的「推荐词典」弹窗（已装项不可勾选）与控制通道 `dict install` 共用这一处，
/// 不各写一份。
///
/// 文件不在的那本（[fileHealth] 判 [DictionaryFileIssue.missing]）不算已装：只剩元数据，
/// 用户得能勾上重下（反馈 ujt4V8GdT8）；重下时以它为显式替换目标
/// （[recommendedDictionaryRestoreTarget]），保住顺序 / 开关 / 改名。暂时读不到的照算已装。
bool isRecommendedDictionaryInstalled(
  Iterable<Dictionary> installed,
  RecommendedDictionary rec, {
  required DictionaryFileHealth fileHealth,
}) => installed.any(
  (Dictionary d) =>
      _claims(d, rec) &&
      fileHealth.issueOf(d.name) != DictionaryFileIssue.missing,
);

/// 推荐词典 [rec] 认领的已装词典里文件不在的那本（重下时的显式替换目标）；没有为 null。
/// 只在 [isRecommendedDictionaryInstalled] 为 false 时有意义。
Dictionary? recommendedDictionaryRestoreTarget(
  Iterable<Dictionary> installed,
  RecommendedDictionary rec, {
  required DictionaryFileHealth fileHealth,
}) {
  for (final Dictionary d in installed) {
    if (_claims(d, rec) &&
        fileHealth.issueOf(d.name) == DictionaryFileIssue.missing) {
      return d;
    }
  }
  return null;
}

/// 已装词典 [d] 是不是推荐条目 [rec] 那一本（按 [RecommendedDictionary.matchPrefix] 认领）。
bool _claims(Dictionary d, RecommendedDictionary rec) {
  final String base = DictionaryRepository.baseName(d.name);
  if (base == rec.matchPrefix) return true;
  if (d.name == rec.matchPrefix) return true;
  return d.name.startsWith(rec.matchPrefix) &&
      d.name.substring(rec.matchPrefix.length).trimLeft().startsWith('[');
}

/// TODO-1075：初装即把「可更新性」权威信号锚定在 catalog 来源真值上。
///
/// 存在分离 index.json 端点的来源（yomidevs releases / wty）回填 isUpdatable +
/// indexUrl + downloadUrl 三件套；其余来源只回填 downloadUrl，可更新性交回词典包自身
/// index.json 的声明。
Map<String, String> recommendedDictionarySourceOverride(
  RecommendedDictionary rec,
) {
  final String? indexUrl = rec.indexUrl;
  return indexUrl != null
      ? <String, String>{
          'isUpdatable': 'true',
          'indexUrl': indexUrl,
          'downloadUrl': rec.url,
        }
      : <String, String>{'downloadUrl': rec.url};
}

/// 推荐词典临时下载目录（词典资源目录下的 `download_temp`），与词典管理页同址。
Directory recommendedDictionaryTempDir(AppModel model) => Directory(
  '${model.dictionaryResourceDirectory.path}${Platform.pathSeparator}download_temp',
);

/// 下载并导入一本推荐词典（词典管理页「推荐词典」弹窗与控制通道 `dict install` 共用）。
///
/// 必须在 [DictionaryDownloadController.run] 的 body 里调用（需要 [job]）。
/// 先下载（可取消，进度写 [job.progress]，字节数经 [onBytes] 回调给调用方拼文案），
/// 下完调 [onDownloaded]（调用方在这里切导入阶段 UI / 记录「下载已成功」），
/// 再经 [AppModel.importDictionary] 导入。失败原样抛出，由调用方分类。
///
/// 这本推荐词典认领的已装词典文件不在时（[recommendedDictionaryRestoreTarget]）以它为显式
/// 替换目标导入：同名不会被判「已是最新」跳过，顺序 / 开关 / 改名照旧（反馈 ujt4V8GdT8）。
Future<void> downloadAndImportRecommendedDictionary({
  required AppModel appModel,
  required RecommendedDictionary rec,
  required DictionaryDownloadJob job,
  required Directory tempDir,
  void Function(int received, int total)? onBytes,
  void Function()? onDownloaded,
}) async {
  final Dictionary? restoreTarget = recommendedDictionaryRestoreTarget(
    appModel.dictionaries,
    rec,
    fileHealth: DictionaryFileHealthMonitor.instance.value,
  );
  final File zipFile = await DictionaryDownloader.download(
    url: rec.url,
    tempDir: tempDir,
    progressNotifier: job.progress,
    cancelToken: job.cancelToken,
    onBytes: onBytes ?? (int received, int total) {},
    // BUG-3887 续：iOS 进程被回收后新进程据此接着下、按同一配方导入。
    handoffPayload:
        (restoreTarget == null
                ? DictionaryImportRecipe.install(
                    name: rec.name,
                    sourceOverride: recommendedDictionarySourceOverride(rec),
                  )
                : DictionaryImportRecipe.update(
                    name: rec.name,
                    replaceTargetName: restoreTarget.name,
                    sourceOverride: recommendedDictionarySourceOverride(rec),
                  ))
            .toPayload(),
  );
  onDownloaded?.call();
  await appModel.importDictionary(
    file: zipFile,
    progressNotifier: job.message,
    onImportSuccess: () {},
    sourceOverride: recommendedDictionarySourceOverride(rec),
    replaceTarget: restoreTarget,
  );
}
