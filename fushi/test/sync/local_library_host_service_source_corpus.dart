import '../helpers/part_corpus.dart';

/// B4（2026-09 同步/互联重构）：`AppModelLibraryHostService` 改名
/// `LocalLibraryHostService`（它不依赖 AppModel，只是「本机库」的 host 实现），并从
/// `local_library_host_service.dart` 拆成主库 + `local_library_host_service/*.part.dart`
/// 一组按域 part（dictionaries / books / local_audio / audiobooks / videos /
/// sync_state）。构造/字段/跨域共享 helper 留在主库，各域方法搬进 part（同一 library
/// 的私有作用域，方法逐字不动、以 mixin 挂回具体类；mixin 体内看不到宿主类 static，故 private static
/// helper 提到库顶层）。
///
/// 原来读单文件的静态守卫改读这份「合并语料」：主库 + 磁盘枚举的全部 part 文件按
/// 路径排序拼接（同 [readSyncSettingsSchemaSource] 的理由：手写 part 清单实测会漏，
/// 漏掉的 part 里负向断言真空通过）。
const String _localLibraryHostShell =
    'lib/src/sync/local_library_host_service.dart';
const String kLocalLibraryHostPartDir =
    'lib/src/sync/local_library_host_service';

/// 主库 + 磁盘上全部 `*.part.dart`（按路径排序）。
List<String> localLibraryHostServiceFiles() => partCorpusFiles(
      shell: _localLibraryHostShell,
      partDir: kLocalLibraryHostPartDir,
    );

/// 读「本机库 host 服务合并语料」：主库 + 全部 part 拼成单个字符串，换行统一成 '\n'。
String readLocalLibraryHostServiceSource() =>
    readPartCorpus(localLibraryHostServiceFiles());
