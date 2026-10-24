/// 互联文件箱的「同步根树列举」能力协商（BUG-3703）。
///
/// 书阶段原本对每本书各发一次 PROPFIND Depth 1；host 支持树列举后，client 对同步根
/// 发一次 `Depth: infinity` 就拿到「根 / 子文件夹 / 文件」两层全貌。
///
/// **为什么必须显式协商**：老 host 的 PROPFIND 只认 Depth 1，其余（含 infinity）一律
/// 当 Depth 0、只回根自身。client 若把那份回包当成树列举，会得出「远端一本书文件夹
/// 都没有」——每本书都按「远端无进度」判方向，可能拿本地旧进度覆盖远端。回包里有没
/// 有深层条目不能当判据（空文件箱与老 host 长得一样），所以只认 host 在
/// `/api/capabilities` 上的显式声明。
library;

/// `/api/capabilities` 顶层的 WebDAV 能力分组键。
const String kInterconnectDavCapabilityGroup = 'webdav';

/// `webdav` 分组下的字段：host 对 `PROPFIND Depth: infinity` 会**完整**列出的层数
/// （1 = 只到直接子项；2 = 子项及孙项）。老 host 无此字段。
const String kInterconnectDavTreeListingLevelsField = 'treeListingLevels';

/// 本 host 实现的树列举层数上限：同步根布局只有两层，再深不列（有界，防无限递归）。
const int kDavTreeListingMaxLevels = 2;

/// 从 `/api/capabilities` 的解码结果读 host 公布的树列举层数；老 host / 字段缺失 /
/// 形状不对一律返回 0（= 不支持）。
int interconnectDavTreeListingLevels(Object? capabilities) {
  if (capabilities is! Map) return 0;
  final Object? group = capabilities[kInterconnectDavCapabilityGroup];
  if (group is! Map) return 0;
  final Object? levels = group[kInterconnectDavTreeListingLevelsField];
  return levels is int && levels > 0 ? levels : 0;
}
