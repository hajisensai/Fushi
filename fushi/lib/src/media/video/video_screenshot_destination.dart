/// 视频截图的**去向**：截完这张图往哪儿放。
///
/// 三档对应三种真实用法，差异是有意的、不能合并：
/// - [ask]：每次弹保存对话框自己挑路径（桌面）/ 交给系统分享面板（移动端）。这是
///   历史行为，保持默认，老用户升级后按键手感不变。
/// - [clipboard]：直接进系统剪贴板，截完立刻能粘进聊天窗 / 笔记 / 制卡工具。高频
///   取图的人要的就是零对话框。
/// - [directory]：静默写进 [kVideoScreenshotDirectoryPref] 指定的目录，同样零对话框，
///   但留下文件。连着截一串图时这条比剪贴板更有用（剪贴板只留得住最后一张）。
///
/// 目录为空（没设过）时 [directory] 会在执行期回退到 [ask] 并提示——宁可多一次对话框，
/// 也不要把文件静默写到用户不知道的地方。
enum VideoScreenshotDestination {
  /// 弹保存对话框 / 系统分享面板（默认，历史行为）。
  ask('ask'),

  /// 写进系统剪贴板。
  clipboard('clipboard'),

  /// 静默保存到用户指定目录。
  directory('directory');

  const VideoScreenshotDestination(this.storageValue);

  /// 落盘值，**冻结**：改标识符不要动它，老库里存的就是这些字符串。
  final String storageValue;

  static VideoScreenshotDestination fromStorage(String? value) {
    for (final VideoScreenshotDestination d in values) {
      if (d.storageValue == value) return d;
    }
    return VideoScreenshotDestination.ask;
  }
}

/// 偏好键（Drift `preferences`）：截图去向。
const String kVideoScreenshotDestinationPref = 'video_screenshot_destination';

/// 偏好键（Drift `preferences`）：[VideoScreenshotDestination.directory] 的目标目录。
///
/// 空串 = 未设置。**不随 Profile 走**（登记在 `ProfileKeys` 的排除名单里）：目录描述
/// 的是这台设备的磁盘，换 Profile 不该把截图重定向到本机不存在的路径——与
/// `download_save_root` 同族同理。
const String kVideoScreenshotDirectoryPref = 'video_screenshot_directory';
