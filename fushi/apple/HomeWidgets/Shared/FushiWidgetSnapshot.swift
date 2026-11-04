import Foundation

#if os(macOS)
  import Security
#endif

/// 主 app 与 FushiWidgets 扩展共用（两个 target 都编译本文件）。
///
/// 数据流：Dart 的 `WidgetSnapshotSource` → `WidgetSnapshotPublisher`（与 Android **同一份**
/// JSON、同一个 `app.fushi.reader/widgets` 通道的 `updateSnapshot`）→ 主 app 里的
/// `FushiWidgetSnapshotSink`（FushiHomeWidgets.swift）把 `cover` 指向的本机封面缩略后拷进
/// `<App Group>/home_widgets/covers/`、改写成相对路径，整份写成 `home_widgets/snapshot.json`，
/// 再 `WidgetCenter.reloadAllTimelines()`。契约见 docs/agent/android-widgets.md。
/// 所有用户可见文字都由 Dart 按 **app 内语言** 预先排好（`labels`），扩展只负责排版。
enum FushiAppGroup {
  /// iOS：Info.plist `FushiAppGroup` = `$(FUSHI_APP_GROUP)`（xcconfig 里定义）。
  ///
  /// macOS：以**本进程签进去的** `com.apple.security.application-groups` 为准，Info.plist
  /// 只作兜底。macOS 的组名要带 Team ID 前缀（`<TEAM>.app.fushi.reader`），而 Team ID 只有
  /// CI 的 Developer ID 重签那一步才知道（Xcode 构建时是 ad-hoc），编进 Info.plist 的值会
  /// 与最终签名对不上；app 与扩展各自读自己的签名，两边天然一致。
  static let identifier: String? = {
    #if os(macOS)
      if let task = SecTaskCreateFromSelf(nil),
        let groups = SecTaskCopyValueForEntitlement(
          task, "com.apple.security.application-groups" as CFString, nil) as? [String],
        let first = groups.first(where: { !$0.isEmpty && !$0.contains("$(") })
      {
        return first
      }
    #endif
    let value = Bundle.main.object(forInfoDictionaryKey: "FushiAppGroup") as? String
    guard let value, !value.isEmpty, !value.contains("$(") else { return nil }
    return value
  }()

  /// 没签 App Group（未签名侧载包、描述文件没勾 App Groups）时为 nil：
  /// 小组件显示「打开 Fushi 一次」占位，主 app 不写快照。
  static var containerURL: URL? {
    guard let identifier else { return nil }
    return FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: identifier)
  }

  static var widgetsDirectory: URL? {
    containerURL?.appendingPathComponent("home_widgets", isDirectory: true)
  }

  static var snapshotURL: URL? {
    widgetsDirectory?.appendingPathComponent("snapshot.json")
  }

  /// 快照里的相对路径（`covers/abc.jpg`）→ 绝对 URL；越出目录的路径一律拒绝。
  static func resolve(_ relative: String?) -> URL? {
    guard let relative, !relative.isEmpty, !relative.contains(".."),
      !relative.hasPrefix("/"), let base = widgetsDirectory
    else { return nil }
    return base.appendingPathComponent(relative)
  }
}

/// `snapshot.json` 的形状 = Dart `buildWidgetSnapshot()`（fushi/lib/src/platform/widget_snapshot.dart）
/// 的输出，只解码 Apple 小组件用到的字段；其余字段（Android 专用的 downloads / onDeck…）
/// 忽略。所有字段都按「可能缺」解码：Dart 侧新增 / 删减字段不会让整份快照解不出来。
/// 唯一例外是 `v`：契约版本对不上就当没有快照（显示「打开 Fushi」占位）。
struct FushiWidgetSnapshot: Decodable {
  /// 与 Dart `kWidgetSnapshotVersion` 一致。
  static let currentVersion = 2

  var v: Int
  /// 统计日 key（`yyyy-MM-dd`）。
  var day: String
  /// 生成时刻（epoch 毫秒）。
  var generatedAt: Double
  var labels: [String: String]
  var privacy: Privacy
  var modules: [String: Bool]
  /// 书架（按最近活动倒序，第一张就是「继续」）。
  var shelf: [Media]
  var today: Today?
  var month: Month?
  var streak: Streak?
  var srs: Srs?
  var vocab: [Vocab]
  var nowPlaying: NowPlaying?
  /// 近 16 周（112 天）热力图；旧快照没有时为 nil（视图退回 35 天的 `month`）。
  var heatmap: Heatmap?
  /// 下一个统计日的样子与切换时刻；timeline 在 `rollover.at` 换上（见 [resolved(at:)]）。
  var rollover: Rollover?

  struct Privacy: Decodable {
    var hideTitles: Bool
    var hideDefinitions: Bool

    init(hideTitles: Bool = false, hideDefinitions: Bool = false) {
      self.hideTitles = hideTitles
      self.hideDefinitions = hideDefinitions
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: AnyKey.self)
      hideTitles = c.bool("hideTitles")
      hideDefinitions = c.bool("hideDefinitions")
    }
  }

  struct Media: Decodable, Hashable {
    /// `book` / `manga` / `video` / `game`（Dart `WidgetMediaKind.wire`）。
    var kind: String
    var id: String
    var title: String
    var subtitle: String
    /// 0…1；0 = 没有进度（不画进度条）。
    var progress: Double
    /// App Group 里的相对路径（主 app 已改写）；空串 = 没有封面。
    var cover: String
    /// 「63%」之类；没有进度为空串。
    var position: String
    /// 「还需 2 小时」之类；估不出来为空串。
    var remaining: String
    /// 点卡片打开的深链，Dart 给好（本机条目 `continue`、服务器条目 `server`、互联远端
    /// 条目对应 tab）；旧快照没有时按 `kind` / `id` 拼 `continue`。
    var link: String

    init(
      kind: String, id: String, title: String, subtitle: String = "", progress: Double = 0,
      cover: String = "", position: String = "", remaining: String = "", link: String = ""
    ) {
      self.kind = kind
      self.id = id
      self.title = title
      self.subtitle = subtitle
      self.progress = progress
      self.cover = cover
      self.position = position
      self.remaining = remaining
      self.link = link.isEmpty ? FushiLinks.continueItem(kind: kind, id: id) : link
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: AnyKey.self)
      kind = c.string("kind")
      id = c.string("id")
      title = c.string("title")
      subtitle = c.string("subtitle")
      progress = c.double("progress")
      cover = c.string("cover")
      position = c.string("position")
      remaining = c.string("remaining")
      let decoded = c.string("link")
      link = decoded.isEmpty ? FushiLinks.continueItem(kind: kind, id: id) : decoded
    }
  }

  struct Today: Decodable {
    /// 今日沉浸时长（已格式化）。
    var time: String
    var chars: String
    var streak: Int

    init(time: String, chars: String, streak: Int) {
      self.time = time
      self.chars = chars
      self.streak = streak
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: AnyKey.self)
      time = c.string("time")
      chars = c.string("chars")
      streak = c.int("streak")
    }
  }

  struct Month: Decodable {
    /// 最近 35 天每天的沉浸分钟数，最旧 → 今天。
    var minutes: [Int]
    var time: String
    var activeDays: Int
    /// `minutes[0]` 那天的 ISO 星期（周一 = 1）。
    var firstWeekday: Int

    init(minutes: [Int], time: String, activeDays: Int, firstWeekday: Int) {
      self.minutes = minutes
      self.time = time
      self.activeDays = activeDays
      self.firstWeekday = firstWeekday
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: AnyKey.self)
      minutes = (try? c.decode([Int].self, forKey: AnyKey("minutes"))) ?? []
      time = c.string("time")
      activeDays = c.int("activeDays")
      firstWeekday = max(1, min(7, c.int("firstWeekday", default: 1)))
    }
  }

  struct Streak: Decodable {
    var current: Int
    var longest: Int
    /// 最近 7 天是否有沉浸活动，最旧 → 今天。
    var week: [Bool]

    init(current: Int, longest: Int, week: [Bool]) {
      self.current = current
      self.longest = longest
      self.week = week
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: AnyKey.self)
      current = c.int("current")
      longest = c.int("longest")
      week = (try? c.decode([Bool].self, forKey: AnyKey("week"))) ?? []
    }
  }

  struct Srs: Decodable {
    /// `fushi` / `anki` / `none`。只有 `fushi` 时带计数（两个 provider 的数永不混）。
    var provider: String
    var due: Int
    var newCount: Int
    var learn: Int
    var review: Int
    var reviewedToday: Int
    /// 待复习数的预排（Dart `buildWidgetSrsDueTimeline`）：只有晚于生成时刻的变化点
    /// （学习步到期 / SRS 换日）；「现在」就是 `due`。只有 `fushi` 时有。
    var timeline: [DueStep]

    var enabled: Bool { provider == "fushi" }

    init(
      provider: String, due: Int = 0, newCount: Int = 0, learn: Int = 0, review: Int = 0,
      reviewedToday: Int = 0, timeline: [DueStep] = []
    ) {
      self.provider = provider
      self.due = due
      self.newCount = newCount
      self.learn = learn
      self.review = review
      self.reviewedToday = reviewedToday
      self.timeline = timeline
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: AnyKey.self)
      provider = c.string("provider", default: "none")
      due = c.int("due")
      newCount = c.int("new")
      learn = c.int("learn")
      review = c.int("review")
      reviewedToday = c.int("reviewedToday")
      timeline = (try? c.decode([DueStep].self, forKey: AnyKey("timeline"))) ?? []
    }

    /// `date` 时刻该显示的待复习数：`at <= date` 的最后一点；一点都没过就是 `due`。
    func dueCount(at date: Date) -> Int {
      let ms = date.timeIntervalSince1970 * 1000
      return timeline.last(where: { $0.at <= ms })?.due ?? due
    }
  }

  struct DueStep: Decodable {
    /// epoch 毫秒。
    var at: Double
    var due: Int

    init(at: Double, due: Int) {
      self.at = at
      self.due = due
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: AnyKey.self)
      at = c.double("at")
      due = c.int("due")
    }
  }

  struct Heatmap: Decodable {
    /// 每天 0…4 档（Dart `widgetHeatLevel`，固定阈值），最旧 → 今天。
    var levels: [Int]
    /// `levels[0]` 那天的 ISO 星期（周一 = 1）。
    var firstWeekday: Int
    var time: String
    var activeDays: Int

    init(levels: [Int], firstWeekday: Int, time: String = "", activeDays: Int = 0) {
      self.levels = levels
      self.firstWeekday = firstWeekday
      self.time = time
      self.activeDays = activeDays
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: AnyKey.self)
      levels = ((try? c.decode([Int].self, forKey: AnyKey("levels"))) ?? []).map { max(0, min(4, $0)) }
      firstWeekday = max(1, min(7, c.int("firstWeekday", default: 1)))
      time = c.string("time")
      activeDays = c.int("activeDays")
    }
  }

  /// 零点切换：Dart 按**下一个统计日**把只依赖日期的块再算一遍（今日清零、连续天数按
  /// 规则延续或中断、周 / 月 / 热力图左移一格）。扩展不做任何日期推算，到点整块换上。
  struct Rollover: Decodable {
    /// 下一个统计日边界（epoch 毫秒，含用户设的翻日时刻）。
    var at: Double
    var day: String
    var today: Today?
    var month: Month?
    var streak: Streak?
    var heatmap: Heatmap?

    init(
      at: Double, day: String, today: Today? = nil, month: Month? = nil, streak: Streak? = nil,
      heatmap: Heatmap? = nil
    ) {
      self.at = at
      self.day = day
      self.today = today
      self.month = month
      self.streak = streak
      self.heatmap = heatmap
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: AnyKey.self)
      at = c.double("at")
      day = c.string("day")
      today = try? c.decode(Today.self, forKey: AnyKey("today"))
      month = try? c.decode(Month.self, forKey: AnyKey("month"))
      streak = try? c.decode(Streak.self, forKey: AnyKey("streak"))
      heatmap = try? c.decode(Heatmap.self, forKey: AnyKey("heatmap"))
    }
  }

  struct Vocab: Decodable, Hashable {
    var term: String
    /// 卡片 / 收藏自带的读音字段；没有就是空串，扩展不显示（不做自动注音）。
    var reading: String
    /// 已去 HTML 的纯文本释义。
    var definition: String
    var sentence: String
    var source: String

    init(term: String, reading: String = "", definition: String = "", sentence: String = "", source: String = "") {
      self.term = term
      self.reading = reading
      self.definition = definition
      self.sentence = sentence
      self.source = source
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: AnyKey.self)
      term = c.string("term")
      reading = c.string("reading")
      definition = c.string("definition")
      sentence = c.string("sentence")
      source = c.string("source")
    }

    var link: String { FushiLinks.lookupWord(term) }
  }

  struct NowPlaying: Decodable {
    /// `music` / `audiobook`。
    var kind: String
    var title: String
    var subtitle: String
    var cover: String
    var positionMs: Double
    var durationMs: Double
    var playing: Bool
    /// 点主体打开的深链（Dart 给好的：音乐 `fushi://widget/music/now`，有声书 continue）。
    var link: String

    init(
      kind: String, title: String, subtitle: String = "", cover: String = "", positionMs: Double = 0,
      durationMs: Double = 0, playing: Bool = false, link: String
    ) {
      self.kind = kind
      self.title = title
      self.subtitle = subtitle
      self.cover = cover
      self.positionMs = positionMs
      self.durationMs = durationMs
      self.playing = playing
      self.link = link
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: AnyKey.self)
      kind = c.string("kind", default: "music")
      title = c.string("title")
      subtitle = c.string("subtitle")
      cover = c.string("cover")
      positionMs = c.double("positionMs")
      durationMs = c.double("durationMs")
      playing = c.bool("playing")
      link = c.string("link", default: FushiLinks.open)
    }

    var progress: Double { durationMs > 0 ? min(max(positionMs / durationMs, 0), 1) : 0 }
  }

  init(
    day: String, generatedAt: Double, labels: [String: String] = [:], privacy: Privacy = Privacy(),
    modules: [String: Bool] = [:], shelf: [Media] = [], today: Today? = nil, month: Month? = nil,
    streak: Streak? = nil, srs: Srs? = nil, vocab: [Vocab] = [], nowPlaying: NowPlaying? = nil,
    heatmap: Heatmap? = nil, rollover: Rollover? = nil
  ) {
    v = Self.currentVersion
    self.day = day
    self.generatedAt = generatedAt
    self.labels = labels
    self.privacy = privacy
    self.modules = modules
    self.shelf = shelf
    self.today = today
    self.month = month
    self.streak = streak
    self.srs = srs
    self.vocab = vocab
    self.nowPlaying = nowPlaying
    self.heatmap = heatmap
    self.rollover = rollover
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: AnyKey.self)
    v = c.int("v", default: -1)
    day = c.string("day")
    generatedAt = c.double("generatedAt")
    labels = (try? c.decode([String: String].self, forKey: AnyKey("labels"))) ?? [:]
    privacy = (try? c.decode(Privacy.self, forKey: AnyKey("privacy"))) ?? Privacy()
    modules = (try? c.decode([String: Bool].self, forKey: AnyKey("modules"))) ?? [:]
    shelf = (try? c.decode([Media].self, forKey: AnyKey("shelf"))) ?? []
    today = try? c.decode(Today.self, forKey: AnyKey("today"))
    month = try? c.decode(Month.self, forKey: AnyKey("month"))
    streak = try? c.decode(Streak.self, forKey: AnyKey("streak"))
    srs = try? c.decode(Srs.self, forKey: AnyKey("srs"))
    vocab = (try? c.decode([Vocab].self, forKey: AnyKey("vocab"))) ?? []
    nowPlaying = try? c.decode(NowPlaying.self, forKey: AnyKey("nowPlaying"))
    heatmap = try? c.decode(Heatmap.self, forKey: AnyKey("heatmap"))
    rollover = try? c.decode(Rollover.self, forKey: AnyKey("rollover"))
  }

  /// `date` 时刻小组件该显示的快照：过了 `rollover.at` 就换上下一个统计日的块（`day`
  /// 一起换，「今日一词」随之轮换）；复习数取预排里该时刻的那一项。只换 Dart 给好的值，
  /// 不推算。
  func resolved(at date: Date) -> FushiWidgetSnapshot {
    var out = self
    if let next = rollover, date.timeIntervalSince1970 * 1000 >= next.at {
      out.day = next.day
      if let value = next.today { out.today = value }
      if let value = next.month { out.month = value }
      if let value = next.streak { out.streak = value }
      if let value = next.heatmap { out.heatmap = value }
      out.rollover = nil
    }
    if var srs = out.srs, srs.enabled {
      srs.due = srs.dueCount(at: date)
      out.srs = srs
    }
    return out
  }

  /// timeline 需要换画面的时刻：(`now`, `horizon`] 里的复习预排点与零点切换点。
  func changeDates(after now: Date, until horizon: Date) -> [Date] {
    var dates: Set<Date> = []
    for step in srs?.timeline ?? [] {
      let date = Date(timeIntervalSince1970: step.at / 1000)
      if date > now && date <= horizon { dates.insert(date) }
    }
    if let at = rollover?.at {
      let date = Date(timeIntervalSince1970: at / 1000)
      if date > now && date <= horizon { dates.insert(date) }
    }
    return dates.sorted()
  }

  func label(_ key: String, _ fallback: String) -> String {
    if let value = labels[key], !value.isEmpty { return value }
    return fallback
  }

  /// 模块关着 = false；快照没带该键时按开着处理。
  func moduleEnabled(_ key: String) -> Bool { modules[key] ?? true }

  /// 隐私开关打开时标题换成种类名（与 Android 同口径）。
  func displayTitle(_ media: Media) -> String {
    privacy.hideTitles ? label("kind_\(media.kind)", media.kind) : media.title
  }

  /// 「今日一词」：按统计日在最近的词里轮换（同一天固定同一个词）。
  var wordOfTheDay: Vocab? {
    guard !vocab.isEmpty else { return nil }
    let seed = day.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
    return vocab[seed % vocab.count]
  }

  static func load() -> FushiWidgetSnapshot? {
    guard let url = FushiAppGroup.snapshotURL,
      let data = try? Data(contentsOf: url)
    else { return nil }
    guard let snapshot = try? JSONDecoder().decode(FushiWidgetSnapshot.self, from: data),
      snapshot.v == currentVersion
    else { return nil }
    return snapshot
  }
}

/// 与 Dart `WidgetLink`（fushi/lib/src/platform/widget_links.dart）同一套 `fushi://widget/...`
/// 语法；查词入口复用图标快捷菜单的 `fushi://shortcut/lookup`（Dart `AppShortcut`）。
enum FushiLinks {
  static let open = "fushi://widget/open"
  static let review = "fushi://widget/srs"
  static let stats = "fushi://widget/stats"
  static let cardSettings = "fushi://widget/settings/cards"
  static let lookup = "fushi://shortcut/lookup"
  static let cameraLookup = "fushi://widget/camera_lookup"
  static let clipboardLookup = "fushi://widget/clipboard_lookup"
  static let musicPlayer = "fushi://widget/music/now"
  /// 控制中心「接着听」后台续播不成时的落点：书籍 tab（有声书挂在书籍下面）。
  static let booksTab = "fushi://widget/tab/books"

  static func continueItem(kind: String, id: String) -> String {
    var components = URLComponents()
    components.scheme = "fushi"
    components.host = "widget"
    components.path = "/continue"
    components.queryItems = [URLQueryItem(name: "kind", value: kind), URLQueryItem(name: "id", value: id)]
    return components.string ?? open
  }

  static func lookupWord(_ word: String) -> String {
    var components = URLComponents()
    components.scheme = "fushi"
    components.host = "widget"
    components.path = "/lookup"
    components.queryItems = [URLQueryItem(name: "word", value: word)]
    return components.string ?? lookup
  }
}

/// 宽松解码用的字符串键 + 带默认值的取值（键缺 / 类型不对都回默认值）。
struct AnyKey: CodingKey {
  var stringValue: String
  var intValue: Int? { nil }
  init(_ string: String) { stringValue = string }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}

extension KeyedDecodingContainer where K == AnyKey {
  func string(_ key: String, default value: String = "") -> String {
    (try? decodeIfPresent(String.self, forKey: AnyKey(key))) ?? value
  }

  func int(_ key: String, default value: Int = 0) -> Int {
    if let v = try? decodeIfPresent(Int.self, forKey: AnyKey(key)) { return v }
    if let v = try? decodeIfPresent(Double.self, forKey: AnyKey(key)) { return Int(v) }
    return value
  }

  func double(_ key: String, default value: Double = 0) -> Double {
    (try? decodeIfPresent(Double.self, forKey: AnyKey(key))) ?? value
  }

  func bool(_ key: String, default value: Bool = false) -> Bool {
    (try? decodeIfPresent(Bool.self, forKey: AnyKey(key))) ?? value
  }
}
