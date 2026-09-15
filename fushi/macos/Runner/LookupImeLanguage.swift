import Carbon
import Cocoa

/// 查词输入框的输入法语言（macOS）。
///
/// macOS 的输入法是**系统全局**状态（TISSelectInputSource 切的是整个系统的当前输入
/// 源），所以和 Windows 一样有两条硬约束：
///
/// 1) 只在**已启用**的输入源里找（TISCreateInputSourceList 第二参 false）。用户没
///    启用的输入源不该被我们替他打开——那是改系统配置。
/// 2) 必须记住原来的输入源并还原，否则用户切到别的 app 打字也会是日语。
///
/// 沙盒说明：沙盒下 TISSelectInputSource 有「菜单栏图标变了、实际没切」的已知问题。
/// 本 app 的 Release.entitlements 为了自动更新已经去掉 app-sandbox，正好避开；
/// 如果哪天沙盒回来了，这条路要重新验证。
enum LookupImeLanguage {
  /// 进入查词前的输入源，用于还原。nil = 当前没切过。
  private static var previousSource: TISInputSource?
  private static var appliedSource: TISInputSource?

  static var isActive: Bool { appliedSource != nil }

  /// 切到 tag 指定的语言。tag 为空 = 还原。
  /// 返回 "applied" / "unchanged" / "unavailable" / "failed"，语义与 Windows 侧一致。
  @discardableResult
  static func setLanguage(_ tag: String?) -> String {
    guard let tag, !tag.isEmpty else {
      return restore()
    }
    guard let target = enabledKeyboardSource(matching: tag) else {
      // 用户选的语言系统里没启用对应输入法。静默不动——绝不替他启用。
      return "unavailable"
    }
    if let applied = appliedSource, sameSource(applied, target) {
      return "unchanged"
    }
    if previousSource == nil {
      // 第一次切换才记原输入源：查词页面之间来回跳时，原输入源必须一直是
      // 「进入查词前」那个，而不是上一次我们自己切过去的那个。
      previousSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    }
    guard TISSelectInputSource(target) == noErr else {
      return "failed"
    }
    appliedSource = target
    return "applied"
  }

  @discardableResult
  static func restore() -> String {
    guard appliedSource != nil else {
      return "unchanged"
    }
    defer {
      appliedSource = nil
      previousSource = nil
    }
    guard let previous = previousSource else {
      // 记不住原输入源时不乱猜一个切过去。
      return "unchanged"
    }
    return TISSelectInputSource(previous) == noErr ? "applied" : "failed"
  }

  /// 已启用的键盘输入源里，第一个主语言匹配 tag 的。
  static func enabledKeyboardSource(matching tag: String) -> TISInputSource? {
    for source in enabledKeyboardSources() {
      for language in languages(of: source) {
        if matches(tag: tag, sourceLanguage: language) {
          return source
        }
      }
    }
    return nil
  }

  /// 探针：给集成测试分辨「没装这个语言」和「装了但没切成功」。
  static func probeInfo() -> [String: Any] {
    let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    return [
      "installed": true,
      "active": isActive,
      "currentLanguages": current.map(languages(of:)) ?? [],
      "enabledLanguages": enabledKeyboardSources().flatMap(languages(of:)),
    ]
  }

  private static func enabledKeyboardSources() -> [TISInputSource] {
    let filter =
      [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource]
      as CFDictionary
    // 第二参 false = 只要**已启用**的，不含仅安装未启用的。
    guard
      let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue()
        as? [TISInputSource]
    else {
      return []
    }
    return list
  }

  private static func languages(of source: TISInputSource) -> [String] {
    guard
      let pointer = TISGetInputSourceProperty(
        source, kTISPropertyInputSourceLanguages)
    else {
      return []
    }
    return Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue()
      as? [String] ?? []
  }

  private static func sourceId(_ source: TISInputSource) -> String? {
    guard
      let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
    else {
      return nil
    }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
  }

  private static func sameSource(_ a: TISInputSource, _ b: TISInputSource) -> Bool {
    return sourceId(a) == sourceId(b)
  }

  /// BCP-47 标签与输入源语言是否算同一种。
  ///
  /// 中文简繁要分开（装了拼音打不出繁体）；其它语言只比主语言，地区变体不挑
  /// （en-GB 还是 en-US 都能打英文）。
  static func matches(tag: String, sourceLanguage: String) -> Bool {
    let wanted = tag.lowercased()
    let candidate = sourceLanguage.lowercased()
    guard let wantedPrimary = wanted.split(separator: "-").first,
      let candidatePrimary = candidate.split(separator: "-").first,
      wantedPrimary == candidatePrimary
    else {
      return false
    }
    if wantedPrimary != "zh" {
      return true
    }
    let wantedScript = chineseScript(of: wanted)
    if wantedScript == 0 {
      return true
    }
    return wantedScript == chineseScript(of: candidate)
  }

  /// 0 = 没说，1 = 简体，2 = 繁体。
  private static func chineseScript(of tag: String) -> Int {
    if tag.contains("hans") || tag.contains("-cn") || tag.contains("-sg") {
      return 1
    }
    if tag.contains("hant") || tag.contains("-tw") || tag.contains("-hk")
      || tag.contains("-mo")
    {
      return 2
    }
    return 0
  }
}
