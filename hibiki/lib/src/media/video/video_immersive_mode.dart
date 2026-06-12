enum VideoImmersiveMode {
  full('full'),
  seekAndLookup('seek_and_lookup'),
  lookupOnly('lookup_only'),
  unlockOnly('unlock_only');

  const VideoImmersiveMode(this.storageValue);

  final String storageValue;

  static const VideoImmersiveMode fallback = lookupOnly;

  static VideoImmersiveMode fromStorage(String value) {
    for (final VideoImmersiveMode mode in VideoImmersiveMode.values) {
      if (mode.storageValue == value) return mode;
    }
    return fallback;
  }
}
