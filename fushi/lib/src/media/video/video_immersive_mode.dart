enum VideoImmersiveMode {
  full('full'),
  // 「快捷键 + 查词」：沉浸锁定态放行键盘 / 手柄快捷键 + 逐字查词，屏蔽触摸误触。
  // storageValue 保留旧字符串 'seek_and_lookup'（历史标识符曾为 seekAndLookup / 「跳转+查词」），
  // 不改存储值以免破坏存量偏好（Never break userspace）。
  shortcutAndLookup('seek_and_lookup'),
  lookupOnly('lookup_only'),
  unlockOnly('unlock_only');

  const VideoImmersiveMode(this.storageValue);

  final String storageValue;

  static const VideoImmersiveMode fallback = shortcutAndLookup;

  static VideoImmersiveMode fromStorage(String value) {
    for (final VideoImmersiveMode mode in VideoImmersiveMode.values) {
      if (mode.storageValue == value) return mode;
    }
    return fallback;
  }
}
