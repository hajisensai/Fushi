/// 互联通道上的「配置文件」（Profile）传输契约。
///
/// 用户诉求：把一台设备上调好的**配置**搬到另一台已配对设备，而不是每台重配一遍。
/// 本仓中文 UI 里的「配置」就是 Profile（见「配置管理」页），其分享产物是
/// `<名字>.fushiprofile.json`。
///
/// 为什么复用 Profile 的分享 JSON 而不是另造 wire 格式：`ProfileRepository`
/// 的 `exportProfileToJson` / `importProfileFromJson` 已经把三件难事做完了——
///   * 凭据剔除（与备份 zip 共用 `PrefRedactionPolicy` 这一唯一真相源）；
///   * 字体绝对路径剥离（导到别的设备缺文件时优雅降级，也不泄漏本机目录结构）；
///   * 文件魔数 `hibiki.profile` + `formatVersion` 校验（导入侧先校验再写 DB，
///     解析失败抛 `ProfileImportException`，事务零破坏）。
/// 再造一份 wire 格式只会让「哪条 key 能出境」多出第二个真相源，正是
/// `PrefRedactionPolicy` 文档里点名要消除的那类分叉。
///
/// 与 `InterconnectServiceConfigSnapshot`（外部服务身份的小白名单）的分工：
/// 那条是**自动跟随**的下行同步，只搬 jimaku/qb/TMDB 之类第三方服务身份；本条是
/// 用户**显式点一次**的整份 Profile 搬运（阅读器排版、制卡字段、快捷键……），
/// 双向，且两个方向都受 host 侧的接收/交出开关门控。
///
/// 备份包（`.fushi.zip`）不走这条：它已有「用互联做备份后端」的既有通道，且恢复
/// 需要关库 + 重启进程，不属于「一个动作按钮」的语义。
library;

/// Host 侧可选能力，与 `FushiLibraryHostService` 的大接口分开（同
/// `InterconnectServiceConfigHost` 的理由：老实现 / 测试 fake 不必跟着实现新方法）。
abstract interface class InterconnectProfileHost {
  /// host 侧用户开关：是否允许**已配对设备**读取 / 写入本机配置。默认关。
  ///
  /// 没有这道门，入站 PUT 就是「无 UI 无开关的隐形写入通道」（BUG-988 点名要避免的
  /// 形状）。能力协商只回答「这台 host 懂这个端点」，此刻允不允许由本开关决定 ——
  /// 所以关着时端点返回 **403 而不是 404**，client 才能把「不支持」与「关着」分开报。
  Future<bool> isInterconnectProfileTransferEnabled();

  /// 导出 host **当前激活 Profile** 的分享 JSON。
  ///
  /// 产物与「配置管理」页的导出完全一致（已剔凭据、已剥字体绝对路径）。
  Future<String> exportInterconnectProfile();

  /// 把对端上传的 Profile JSON 作为**新** Profile 导入本机，返回新建的 Profile 名。
  ///
  /// 永远 `createNew`：入站数据不得覆盖 host 上任何既有 Profile，更不得改动当前
  /// 激活的那个——用户在 host 上仍要自己去「配置管理」里切过去才生效。
  ///
  /// 载荷不是合法的 Profile 导出（魔数 / 版本 / 结构不对）时抛 [FormatException]；
  /// 实现方负责把 `ProfileImportException` 翻成它，好让 wire 层不必依赖 profile 层的
  /// 异常类型就能回 400。解析在写库之前完成，失败时 host 的 DB 零改动。
  Future<String> importInterconnectProfile(String json);
}

/// 互联「配置文件」端点路径（host 与 client 共用的唯一字面量）。
const String kInterconnectProfilePath = '/api/interconnect/profile';
