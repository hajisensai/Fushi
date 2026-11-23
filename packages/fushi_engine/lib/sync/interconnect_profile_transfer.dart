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

import 'dart:convert';

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
  ///
  /// host 上**此刻没有可交出的配置**（无头服务端还没收到过任何对端推来的配置）时抛
  /// [InterconnectProfileUnavailableException]，wire 层回 409——不能回 404（client 会
  /// 当成「对端不支持」），也不能回 500（那是 host 坏了）。
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

/// host 懂这个端点、开关也开着，但眼下没有可交出的配置（见
/// [InterconnectProfileHost.exportInterconnectProfile]）。
class InterconnectProfileUnavailableException implements Exception {
  const InterconnectProfileUnavailableException(this.message);
  final String message;
  @override
  String toString() => 'InterconnectProfileUnavailableException: $message';
}

/// 互联「配置文件」端点路径（host 与 client 共用的唯一字面量）。
const String kInterconnectProfilePath = '/api/interconnect/profile';

/// host 拒绝配置搬运的原因（wire 值见 [code]，错误响应体是 `{"error": code}`）。
///
/// 反馈 G-ebgSnoK8：以前这几种拒绝回的是英文自由文本（`Profile transfer disabled
/// on host`），client 只能原样拼进「服务端拒绝了这次请求：……」上屏，既没翻译也没
/// 说该去哪里开开关。改成结构化码，client 按码给出本地化的可操作原因。
enum InterconnectProfileDenial {
  /// 会话不是 TLS：整份配置不走明文。
  httpsRequired('https_required'),

  /// 没带已配对设备的专属 token（共享 token 不收）。
  peerTokenRequired('peer_token_required'),

  /// host 上「读写本机配置」开关关着（默认关）。
  disabled('profile_transfer_disabled'),

  /// 开关开着，但 host 眼下没有可交出的配置（见
  /// [InterconnectProfileHost.exportInterconnectProfile]）。
  unavailable('profile_unavailable');

  const InterconnectProfileDenial(this.code);

  final String code;

  /// 对应的 HTTP 状态码：「没东西可给」是 409，其余是明确拒绝 403。
  int get httpStatus => this == unavailable ? 409 : 403;

  static InterconnectProfileDenial? fromCode(Object? raw) {
    for (final InterconnectProfileDenial d
        in InterconnectProfileDenial.values) {
      if (d.code == raw) return d;
    }
    return null;
  }
}

/// 拒绝响应正文。
String interconnectProfileDenialBody(InterconnectProfileDenial denial) =>
    jsonEncode(<String, String>{'error': denial.code});

/// 从错误响应正文里取拒绝原因（不是 JSON / 没有认得的 error 码 → null）。
InterconnectProfileDenial? parseInterconnectProfileDenialBody(String body) {
  try {
    final Object? decoded = jsonDecode(body);
    if (decoded is Map) {
      return InterconnectProfileDenial.fromCode(decoded['error']);
    }
  } on FormatException {
    return null;
  }
  return null;
}

/// client 收到 host 的结构化拒绝时抛出，UI 按 [denial] 给出本地化原因。
class InterconnectProfileRejected implements Exception {
  const InterconnectProfileRejected(this.denial, {this.statusCode});

  final InterconnectProfileDenial denial;
  final int? statusCode;

  @override
  String toString() => 'InterconnectProfileRejected(${denial.code})';
}
