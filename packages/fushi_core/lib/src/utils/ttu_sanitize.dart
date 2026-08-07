/// ッツ Ebook Reader 兼容的文件名 sanitize（hibiki_core 私有副本，不 barrel-export）。
///
/// app 侧真相源在 `hibiki/lib/src/sync/ttu_filename.dart`；这里保留一份逐字节等价的
/// 副本，供 v38 拆集迁移在 core 内派生视频每集 bookUid（core 不能依赖 app 层）。刻意
/// **不**从 hibiki_core barrel 导出（否则同时 import barrel + ttu_filename 的 app 文件
/// 会触发 unnecessary_import 警告）。两份由 `video_book_uid_core_parity_test` 守卫，
/// 任一处改了必须同步另一处。
///
/// 纯字符串变换，无 IO / 无平台依赖。格式与 ッツ web 实现一致（冻结，不随意改——
/// 改了会让既有书/视频的跨设备身份键漂移）。
String sanitizeTtuFilename(String title) {
  String result = title;
  if (result.endsWith(' ')) {
    result = '${result.substring(0, result.length - 1)}~ttu-spc~';
  }
  if (result.endsWith('.')) {
    result = '${result.substring(0, result.length - 1)}~ttu-dend~';
  }
  result = result.replaceAll('*', '~ttu-star~');
  result = result.replaceAllMapped(
    RegExp(r'[/?\<>\\:|%"]'),
    (match) => match[0]!
        .codeUnits
        .map((c) => '%${c.toRadixString(16).toUpperCase().padLeft(2, '0')}')
        .join(),
  );
  return result;
}
