// KiriKiri 游戏内查词（v14 查词区）的**会话 replay**。
//
// 回放 tests/fixtures/kirikiri_lookup_replay.tsv 里的一整场事件流，跑在一块按真实
// injector 布局摆好的假共享内存上，钉死这些会话级不变量：
//
//   1. 正常时序 hit → frame → apply 走得通，且卡片像素真的落进了"游戏图层"；
//   2. 回应旧命中的迟到帧必须被丢弃（连点两下时不许把上一个词的卡片贴出来 = 串卡）；
//   3. `lookup_enabled == 0` 时注入侧**一个字节都不写**（开关是唯一入口，不是"少写点"）；
//   4. 落在卡片矩形外的输入不进转发环（否则游戏自己的点击会被吃掉）；
//   5. 会话结束必须清理未完成状态，下一会话不串数据；
//   6. **收卡**：dismiss 帧按定义没有像素（过不了 IsLookupFrameSane），但必须被应用；
//      而**陈旧的 dismiss 绝不能收掉更新的卡片**。
//
// 第 6 条是有血的教训：`LookupFrame::seq` 曾经既当发布序又当"回应哪次 hit"，于是收卡帧
// 只能复用被撤那张卡的 seq，而那个 seq 刚 present 过，被注入侧当陈旧帧扔掉——补 0×0
// 分支也救不回来，因为帧压根进不了候选。根因是数据结构，不是漏分支。拆成
// `seq`（发布序）+ `hit_seq`（回应哪次查询）之后收卡不需要任何特例。
//
// 边界说明（不许含糊）：
//   * 寻址、帧校验、**以及"这帧该不该应用"的判据**都用契约头 voice_hook_ipc.h 里那一份
//     真实实现（LookupHitOf / LookupFrameAt / LookupBitmapAt / IsLookupFrameSane /
//     ShouldApplyLookupFrame）。注入侧 PresentKirikiriLookupFrame 调的是同一个函数，
//     所以这条判据不会再出现"参照实现与生产漂移"——上一版本文件里的
//     `if (seq != current)` 就是那样漂开的，收卡整条不通它一声不吭。
//   * 剩下的编排（谁在什么时候写、开关门、卡片矩形命中测试）仍是**契约参照实现**：
//     adapter 那个 .inc 依赖 MinHook/TJS/游戏进程上下文，不能独立编译进测试。它与
//     adapter 一致由 tests/kirikiri_lookup_source_guard_test.py 从源码侧另行钉住。

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "voice_hook_ipc.h"

namespace {

using fushi_voice_hook::IsLookupFrameSane;
using fushi_voice_hook::kClipCount;
using fushi_voice_hook::kLookupBitmapBytes;
using fushi_voice_hook::kLookupFrameCount;
using fushi_voice_hook::kLookupFrameDismiss;
using fushi_voice_hook::kLookupHitFlagSubmit;
using fushi_voice_hook::kLookupInputSlotCount;
using fushi_voice_hook::kLookupLineBytes;
using fushi_voice_hook::kLoopbackMarkerCount;
using fushi_voice_hook::kTextLaneCount;
using fushi_voice_hook::kTextLaneSlotCount;
using fushi_voice_hook::kThreadPreviewCount;
using fushi_voice_hook::LookupBitmapAt;
using fushi_voice_hook::LookupFrame;
using fushi_voice_hook::LookupFrameAt;
using fushi_voice_hook::LookupHitOf;
using fushi_voice_hook::LookupHitSlot;
using fushi_voice_hook::LookupInputSlot;
using fushi_voice_hook::LookupInputsOf;
using fushi_voice_hook::LookupRegionBytes;
using fushi_voice_hook::LoopbackMarker;
using fushi_voice_hook::SharedHeader;
using fushi_voice_hook::ShouldApplyLookupFrame;
using fushi_voice_hook::ThreadPreviewSlot;
using fushi_voice_hook::VoiceClip;

int g_failures = 0;

void Check(bool condition, const std::string& what) {
  if (!condition) {
    ++g_failures;
    fprintf(stderr, "FAIL: %s\n", what.c_str());
  }
}

// ── fixture 解析（`kind key=value ...`，`#` 注释，`expect` 行是黄金值）────────

struct Event {
  std::string kind;
  std::vector<std::pair<std::string, std::string>> fields;

  const std::string* Find(const std::string& key) const {
    for (const auto& field : fields) {
      if (field.first == key) return &field.second;
    }
    return nullptr;
  }
  std::string Str(const std::string& key, const char* fallback = "") const {
    const std::string* value = Find(key);
    return value == nullptr ? std::string(fallback) : *value;
  }
  // 支持 0x 前缀，便于 fixture 里写填充字节。
  long Int(const std::string& key, long fallback = 0) const {
    const std::string* value = Find(key);
    if (value == nullptr) return fallback;
    return strtol(value->c_str(), nullptr, 0);
  }
  // `key=a,b,c,d` 取第 [index] 个分量。
  long IntAt(const std::string& key, size_t index, long fallback = 0) const {
    const std::string* value = Find(key);
    if (value == nullptr) return fallback;
    std::stringstream stream(*value);
    std::string part;
    for (size_t i = 0; std::getline(stream, part, ','); ++i) {
      if (i == index) return strtol(part.c_str(), nullptr, 0);
    }
    return fallback;
  }
};

bool LoadFixture(const char* path, std::vector<Event>* events,
                 std::vector<std::pair<std::string, std::string>>* expected) {
  std::ifstream file(path);
  if (!file.is_open()) return false;
  std::string line;
  while (std::getline(file, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    std::stringstream stream(line);
    std::string token;
    Event event;
    while (stream >> token) {
      if (event.kind.empty()) {
        if (token[0] == '#') break;
        event.kind = token;
        continue;
      }
      const size_t equals = token.find('=');
      if (equals == std::string::npos) continue;
      event.fields.emplace_back(token.substr(0, equals),
                                token.substr(equals + 1));
    }
    if (event.kind.empty()) continue;
    if (event.kind == "expect") {
      for (const auto& field : event.fields) expected->push_back(field);
      continue;
    }
    events->push_back(event);
  }
  return true;
}

// ── 假共享内存（布局照 injector：查词区追加在最尾，后面再压一段守卫字节）──────

constexpr uint8_t kTailGuardByte = 0xA5;
constexpr size_t kTailGuardBytes = 64;

struct FakeMapping {
  static constexpr uint32_t kRingCapacity = 4096;
  static constexpr uint32_t kLoopbackCapacity = 4096;

  std::vector<uint8_t> bytes;
  uint64_t lookup_bytes = 0;
  uint64_t mapped_bytes = 0;  // 不含尾部守卫

  FakeMapping() {
    const uint64_t text_bytes =
        fushi_voice_hook::TextRegionBytes(kTextLaneCount, kTextLaneSlotCount);
    const uint64_t clip_bytes =
        static_cast<uint64_t>(kClipCount) * sizeof(VoiceClip);
    const uint64_t marker_bytes =
        static_cast<uint64_t>(kLoopbackMarkerCount) * sizeof(LoopbackMarker);
    const uint64_t preview_bytes =
        static_cast<uint64_t>(kThreadPreviewCount) * sizeof(ThreadPreviewSlot);
    lookup_bytes = LookupRegionBytes(kLookupInputSlotCount, kLookupFrameCount,
                                     kLookupBitmapBytes);
    mapped_bytes = sizeof(SharedHeader) + kRingCapacity + text_bytes +
                   clip_bytes + kLoopbackCapacity + marker_bytes +
                   preview_bytes + lookup_bytes;
    bytes.assign(static_cast<size_t>(mapped_bytes) + kTailGuardBytes,
                 kTailGuardByte);
    memset(bytes.data(), 0, static_cast<size_t>(mapped_bytes));

    SharedHeader* h = header();
    h->magic = fushi_voice_hook::kSharedMagic;
    h->version = fushi_voice_hook::kSharedVersion;
    h->ring_capacity = kRingCapacity;
    h->text_region_offset =
        static_cast<uint32_t>(sizeof(SharedHeader) + kRingCapacity);
    h->text_lane_count = kTextLaneCount;
    h->text_lane_slot_count = kTextLaneSlotCount;
    h->clip_region_offset =
        static_cast<uint32_t>(h->text_region_offset + text_bytes);
    h->loopback_ring_offset =
        static_cast<uint32_t>(h->clip_region_offset + clip_bytes);
    h->loopback_ring_capacity = kLoopbackCapacity;
    h->loopback_marker_offset =
        static_cast<uint32_t>(h->loopback_ring_offset + kLoopbackCapacity);
    h->loopback_marker_slot_count = kLoopbackMarkerCount;
    h->thread_preview_offset =
        static_cast<uint32_t>(h->loopback_marker_offset + marker_bytes);
    h->thread_preview_slot_count = kThreadPreviewCount;
    h->lookup_region_offset =
        static_cast<uint32_t>(h->thread_preview_offset + preview_bytes);
    h->lookup_bitmap_bytes = kLookupBitmapBytes;
    h->lookup_frame_count = kLookupFrameCount;
    h->lookup_input_slot_count = kLookupInputSlotCount;
  }

  SharedHeader* header() {
    return reinterpret_cast<SharedHeader*>(bytes.data());
  }
  uint8_t* lookup_region() {
    return bytes.data() + header()->lookup_region_offset;
  }
  // v13 及更早的全部区（音频环 / 文本 / clip / loopback / 预览）。查词功能碰到这里
  // 任何一个字节都是越界写。
  uint8_t* legacy_regions() { return bytes.data() + sizeof(SharedHeader); }
  size_t legacy_region_bytes() {
    return static_cast<size_t>(header()->lookup_region_offset) -
           sizeof(SharedHeader);
  }
  bool TailGuardIntact() const {
    for (size_t i = static_cast<size_t>(mapped_bytes); i < bytes.size(); ++i) {
      if (bytes[i] != kTailGuardByte) return false;
    }
    return true;
  }
};

// ── 契约参照实现：hook 侧与 host 侧各自该怎么动这块内存 ───────────────────────

struct Counters {
  // "<会话号>:<发布序>"：被真正取走的帧。发布序是一帧的身份（host 每投一帧 +1）。
  std::vector<std::string> applied_frames;
  // 游戏画面上卡片的出没流水："show:<hit seq>" / "hide:<hit seq>"。
  // 收卡链通不通、陈旧 dismiss 有没有误伤新卡片，看这一行就够。
  std::vector<std::string> card_transcript;
  long last_applied_fill = -1;
  long hits_published = 0;
  long hits_suppressed_while_disabled = 0;
  long frames_published = 0;  // 含 dismiss 帧
  long dismiss_frames_applied = 0;
  // 被应用的 dismiss 帧里有几张过不了 IsLookupFrameSane（按定义应当全部）。
  long dismiss_frames_failing_sanity = 0;
  long insane_frames_rejected = 0;
  long inputs_forwarded = 0;
  long inputs_ignored = 0;
  long bytes_written_while_disabled = 0;
  long cross_session_frames_applied = 0;
  bool session_clean = true;
};

// 「发布了但从没被贴上去」的帧数 = 发布数 - 应用数。
//
// 不按"每轮 poll 拒了几次"记：注入侧**不清 ready**（去重靠 presented_seq 单调），同一
// 张陈旧帧每轮都会被重新看到，按次数记会让黄金值随 poll 条数漂。也不在测试里重新推导
// 「为什么被拒」——那等于把 ShouldApplyLookupFrame 的判据抄第二遍，正是这次要消灭的东西。
long FramesNeverApplied(const Counters& c) {
  return c.frames_published - static_cast<long>(c.applied_frames.size());
}

class LookupSessionModel {
 public:
  explicit LookupSessionModel(FakeMapping* mapping)
      : mapping_(mapping),
        frame_session_(mapping->header()->lookup_frame_count, 0) {}

  Counters& counters() { return counters_; }

  void Run(const std::vector<Event>& events) {
    for (const Event& event : events) {
      // 「未开启时零写入」不是靠信任，是每条事件前后各拍一次查词区的快照来量的。
      std::vector<uint8_t> before;
      const bool disabled = mapping_->header()->lookup_enabled == 0;
      if (disabled) {
        before.assign(mapping_->lookup_region(),
                      mapping_->lookup_region() +
                          static_cast<size_t>(mapping_->lookup_bytes));
      }
      Dispatch(event);
      if (disabled) {
        const uint8_t* after = mapping_->lookup_region();
        for (size_t i = 0; i < before.size(); ++i) {
          if (before[i] != after[i]) ++counters_.bytes_written_while_disabled;
        }
      }
    }
  }

 private:
  void Dispatch(const Event& event) {
    if (event.kind == "enabled") {
      // host→hook 开关。它本身在 header 里，不属于查词区。
      mapping_->header()->lookup_enabled =
          static_cast<uint32_t>(event.Int("value"));
    } else if (event.kind == "hit") {
      PublishHit(event);
    } else if (event.kind == "frame") {
      PublishFrame(event);
    } else if (event.kind == "dismiss") {
      PublishDismiss(event);
    } else if (event.kind == "poll") {
      PollFrames();
    } else if (event.kind == "input") {
      ForwardInput(event);
    } else if (event.kind == "session_end") {
      EndSession();
    } else {
      Check(false, "fixture 里出现未知事件：" + event.kind);
    }
  }

  // hook → host。开关关着时一个字节都不写。
  void PublishHit(const Event& event) {
    SharedHeader* h = mapping_->header();
    if (h->lookup_enabled == 0) {
      ++counters_.hits_suppressed_while_disabled;
      return;
    }
    LookupHitSlot* hit = LookupHitOf(h);
    Check(hit != nullptr, "开启后 hit 槽必须可寻址");
    if (hit == nullptr) return;
    const std::string line = event.Str("line");
    hit->char_index = static_cast<uint32_t>(event.Int("index"));
    hit->char_count = static_cast<uint32_t>(event.Int("chars"));
    hit->glyph_x = static_cast<int32_t>(event.IntAt("glyph", 0));
    hit->glyph_y = static_cast<int32_t>(event.IntAt("glyph", 1));
    hit->glyph_w = static_cast<int32_t>(event.IntAt("glyph", 2));
    hit->glyph_h = static_cast<int32_t>(event.IntAt("glyph", 3));
    hit->view_w = static_cast<int32_t>(event.IntAt("view", 0));
    hit->view_h = static_cast<int32_t>(event.IntAt("view", 1));
    hit->flags = event.Int("submit") != 0 ? kLookupHitFlagSubmit : 0u;
    const uint32_t bytes =
        static_cast<uint32_t>(line.size() < kLookupLineBytes ? line.size()
                                                             : kLookupLineBytes);
    hit->line_bytes = bytes;
    memcpy(hit->line_utf8, line.data(), bytes);
    Check(hit->char_index < hit->char_count,
          "hit 自洽：char_index 必须落在本行字符数内");
    // seq **最后**写（与契约头注释同一套纪律）。
    ++hook_hit_seq_;
    hit->seq = hook_hit_seq_;
    ++h->lookup_hit_count;
    ++counters_.hits_published;
  }

  // host → hook：带像素的一帧。**故意**允许发布不合契约的帧：跨进程来的宽高就是不可信
  // 输入，由取帧侧的闸门挡，而不是靠"写侧不会写错"。
  void PublishFrame(const Event& event) {
    LookupFrame* frame = BeginPublish();
    if (frame == nullptr) return;
    SharedHeader* h = mapping_->header();
    frame->hit_seq = static_cast<uint64_t>(event.Int("hit"));
    frame->flags = 0;
    frame->width = static_cast<uint32_t>(event.Int("w"));
    frame->height = static_cast<uint32_t>(event.Int("h"));
    frame->pitch = static_cast<uint32_t>(event.Int("pitch"));
    frame->anchor_x = static_cast<int32_t>(event.IntAt("anchor", 0));
    frame->anchor_y = static_cast<int32_t>(event.IntAt("anchor", 1));
    frame->highlight_start = static_cast<uint32_t>(event.IntAt("hl", 0));
    frame->highlight_len = static_cast<uint32_t>(event.IntAt("hl", 1));
    frame->byte_len = frame->pitch * frame->height;
    uint8_t* pixels = LookupBitmapAt(h, last_publish_index_);
    Check(pixels != nullptr, "位图缓冲必须可寻址");
    if (pixels != nullptr) {
      // 只按**闸门允许的上限**填，测试自己也不许越界写。
      const uint32_t fill_bytes = frame->byte_len <= h->lookup_bitmap_bytes
                                      ? frame->byte_len
                                      : h->lookup_bitmap_bytes;
      memset(pixels, static_cast<int>(event.Int("fill")), fill_bytes);
    }
    EndPublish(frame);
  }

  // host → hook：收卡。它就是**普通一帧**，只是靠 flags 自述、没有像素。
  // 不用 "width==0 就是收卡" 的魔法编码——那和"host 投了张废帧"在字节上完全一样。
  void PublishDismiss(const Event& event) {
    LookupFrame* frame = BeginPublish();
    if (frame == nullptr) return;
    frame->hit_seq = static_cast<uint64_t>(event.Int("hit"));
    frame->flags = kLookupFrameDismiss;
    frame->width = 0;
    frame->height = 0;
    frame->pitch = 0;
    frame->anchor_x = 0;
    frame->anchor_y = 0;
    frame->highlight_start = 0;
    frame->highlight_len = 0;
    frame->byte_len = 0;
    EndPublish(frame);
  }

  // 发布序由 host 独占递增，槽下标 = 发布序 % 缓冲数（与 voice_hook_reader 同款）。
  LookupFrame* BeginPublish() {
    SharedHeader* h = mapping_->header();
    const uint64_t publish = ++host_publish_seq_;
    last_publish_index_ =
        static_cast<uint32_t>(publish % h->lookup_frame_count);
    LookupFrame* frame = LookupFrameAt(h, last_publish_index_);
    Check(frame != nullptr, "帧槽必须可寻址");
    if (frame == nullptr) return nullptr;
    frame->ready = 0;  // 先熄灯再改内容
    frame->seq = publish;
    frame->reserved = 0;
    frame->reserved2 = 0;
    return frame;
  }

  void EndPublish(LookupFrame* frame) {
    SharedHeader* h = mapping_->header();
    frame->ready = 1;  // ready **最后**写
    frame_session_[last_publish_index_] = session_index_;
    ++h->lookup_frame_count_written;
    ++counters_.frames_published;
  }

  // hook 的 continuous callback。与 PresentKirikiriLookupFrame 同款：扫所有槽，取
  // **发布序最大**的那个还能用的候选；判据一律走契约头的 ShouldApplyLookupFrame。
  //
  // 注意这里**不清 ready**：去重靠 presented_seq 单调，与注入侧一致。清了反而会掩盖
  // 「陈旧帧还躺在共享内存里」这个真实状态，也就测不出"陈旧 dismiss 会不会误伤新卡"。
  void PollFrames() {
    SharedHeader* h = mapping_->header();
    if (h->lookup_enabled == 0) return;
    const LookupHitSlot* hit = LookupHitOf(h);
    if (hit == nullptr) return;
    const uint64_t current_hit = hit->seq;

    LookupFrame* best = nullptr;
    uint32_t best_index = 0;
    uint64_t best_seq = 0;
    for (uint32_t i = 0; i < h->lookup_frame_count; ++i) {
      LookupFrame* frame = LookupFrameAt(h, i);
      if (frame == nullptr || frame->ready == 0) continue;
      const uint64_t seq = frame->seq;
      if (seq <= best_seq) continue;  // 本轮已找到更新的候选
      if (!ShouldApplyLookupFrame(seq, frame->hit_seq, presented_seq_,
                                  current_hit)) {
        continue;
      }
      best = frame;
      best_index = i;
      best_seq = seq;
    }
    if (best == nullptr) return;
    presented_seq_ = best_seq;

    // 收卡必须在 IsLookupFrameSane **之前**认掉：它按定义没有像素，过不了那道校验。
    if ((best->flags & kLookupFrameDismiss) != 0) {
      RecordApplied(best_seq, best_index);
      ++counters_.dismiss_frames_applied;
      if (!IsLookupFrameSane(h, best)) ++counters_.dismiss_frames_failing_sanity;
      card_visible_ = false;
      game_layer_.clear();
      counters_.card_transcript.push_back("hide:" +
                                          std::to_string(best->hit_seq));
      return;
    }

    // 槽下标自洽：发布序决定落哪个槽，对不上说明写侧和读侧对布局的理解漂了。
    if (!IsLookupFrameSane(h, best) ||
        static_cast<uint32_t>(best_seq % h->lookup_frame_count) != best_index) {
      ++counters_.insane_frames_rejected;
      h->lookup_diag |= fushi_voice_hook::kLookupDiagFrameRejected;
      return;
    }
    const uint8_t* pixels = LookupBitmapAt(h, best_index);
    Check(pixels != nullptr, "过闸门的帧必须有可读位图");
    if (pixels == nullptr) return;
    RecordApplied(best_seq, best_index);
    game_layer_.assign(pixels, pixels + best->byte_len);
    Check(best->seq == best_seq, "拷贝期间帧 seq 不得变化");
    card_visible_ = true;
    card_x_ = best->anchor_x;
    card_y_ = best->anchor_y;
    card_w_ = static_cast<int32_t>(best->width);
    card_h_ = static_cast<int32_t>(best->height);
    counters_.last_applied_fill = game_layer_.empty() ? -1 : game_layer_[0];
    counters_.card_transcript.push_back("show:" +
                                        std::to_string(best->hit_seq));
    h->lookup_diag |= fushi_voice_hook::kLookupDiagFramePresented;
  }

  // 只在**真的贴上去了**（或真的收起来了）之后记账，不记"选中了但随后被闸门拒掉"。
  void RecordApplied(uint64_t publish_seq, uint32_t index) {
    counters_.applied_frames.push_back(std::to_string(session_index_) + ":" +
                                       std::to_string(publish_seq));
    // 这一帧是上一会话留下的？那就是"上一局的卡片贴到这一局"——清理没做干净。
    if (frame_session_[index] != session_index_) {
      ++counters_.cross_session_frames_applied;
    }
  }

  // 只有落在卡片矩形内的输入才进转发环；其余留给游戏自己处理。
  void ForwardInput(const Event& event) {
    SharedHeader* h = mapping_->header();
    const int32_t x = static_cast<int32_t>(event.Int("x"));
    const int32_t y = static_cast<int32_t>(event.Int("y"));
    const bool inside = card_visible_ && x >= card_x_ && x < card_x_ + card_w_ &&
                        y >= card_y_ && y < card_y_ + card_h_;
    if (h->lookup_enabled == 0 || !inside) {
      ++counters_.inputs_ignored;
      return;
    }
    LookupInputSlot* ring = LookupInputsOf(h);
    Check(ring != nullptr, "输入环必须可寻址");
    if (ring == nullptr) return;
    const uint64_t seq = h->lookup_input_count + 1;
    LookupInputSlot* slot = &ring[(seq - 1) % h->lookup_input_slot_count];
    slot->x = x - card_x_;  // 卡片局部坐标：host 直接喂给离屏 WebView2
    slot->y = y - card_y_;
    slot->kind = static_cast<uint32_t>(event.Int("kind"));
    slot->wheel = static_cast<int32_t>(event.Int("wheel"));
    slot->keys = static_cast<uint32_t>(event.Int("keys"));
    slot->seq = seq;  // seq **最后**写
    h->lookup_input_count = seq;
    ++counters_.inputs_forwarded;
    Check(slot->x >= 0 && slot->x < card_w_ && slot->y >= 0 &&
              slot->y < card_h_,
          "转发出去的坐标必须已经换算到卡片局部域");
  }

  // 会话结束：注入侧把整块查词区清干净，两侧的序号台账一并归零。
  // 不清就会出现"上一局的卡片贴到这一局"。
  void EndSession() {
    SharedHeader* h = mapping_->header();
    memset(mapping_->lookup_region(), 0,
           static_cast<size_t>(mapping_->lookup_bytes));
    h->lookup_enabled = 0;
    h->lookup_hit_count = 0;
    h->lookup_frame_count_written = 0;
    h->lookup_input_count = 0;
    hook_hit_seq_ = 0;
    host_publish_seq_ = 0;
    presented_seq_ = 0;
    card_visible_ = false;
    game_layer_.clear();
    ++session_index_;

    // 清理是否真的干净，逐项验，不看"应该"。
    const LookupHitSlot* hit = LookupHitOf(h);
    bool clean = hit != nullptr && hit->seq == 0 && hit->line_bytes == 0;
    for (uint32_t i = 0; i < h->lookup_frame_count && clean; ++i) {
      const LookupFrame* frame = LookupFrameAt(h, i);
      clean = frame != nullptr && frame->ready == 0 && frame->seq == 0 &&
              frame->hit_seq == 0 && frame->flags == 0;
    }
    const LookupInputSlot* ring = LookupInputsOf(h);
    for (uint32_t i = 0; i < h->lookup_input_slot_count && clean; ++i) {
      clean = ring != nullptr && ring[i].seq == 0;
    }
    if (!clean) counters_.session_clean = false;
  }

  FakeMapping* mapping_;
  Counters counters_;
  std::vector<uint8_t> game_layer_;  // "游戏渲染树里的卡片 Layer" 的替身
  // 每个帧槽最后一次被写入是在第几个会话（纯测试侧台账，用于识别跨会话残留）。
  std::vector<int> frame_session_;
  uint64_t hook_hit_seq_ = 0;   // hook 侧：命中序
  uint64_t host_publish_seq_ = 0;  // host 侧：帧发布序
  uint64_t presented_seq_ = 0;  // hook 侧：已处理到哪个发布序
  uint32_t last_publish_index_ = 0;
  int session_index_ = 1;
  bool card_visible_ = false;
  int32_t card_x_ = 0;
  int32_t card_y_ = 0;
  int32_t card_w_ = 0;
  int32_t card_h_ = 0;
};

std::string Join(const std::vector<std::string>& values) {
  std::string joined;
  for (size_t i = 0; i < values.size(); ++i) {
    if (i != 0) joined += ",";
    joined += values[i];
  }
  return joined;
}

std::string Hex(long value) {
  char buffer[16] = {};
  snprintf(buffer, sizeof(buffer), "0x%02lX", value & 0xFF);
  return buffer;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: lookup_session_replay_test <fixture.tsv>\n");
    return 2;
  }
  std::vector<Event> events;
  std::vector<std::pair<std::string, std::string>> expected;
  if (!LoadFixture(argv[1], &events, &expected)) {
    fprintf(stderr, "cannot read fixture: %s\n", argv[1]);
    return 2;
  }
  Check(!events.empty(), "fixture 必须有事件");
  Check(!expected.empty(), "fixture 必须有 expect 黄金值");

  FakeMapping mapping;
  const std::vector<uint8_t> legacy_before(
      mapping.legacy_regions(),
      mapping.legacy_regions() + mapping.legacy_region_bytes());

  LookupSessionModel model(&mapping);
  model.Run(events);
  Counters& c = model.counters();

  const bool legacy_untouched =
      memcmp(legacy_before.data(), mapping.legacy_regions(),
             mapping.legacy_region_bytes()) == 0;

  // 黄金值比对：回放过程一个字都没读过 expect，这里才第一次看它。
  for (const auto& item : expected) {
    const std::string& key = item.first;
    const std::string& want = item.second;
    std::string got;
    if (key == "applied_frames") {
      got = Join(c.applied_frames);
    } else if (key == "card_transcript") {
      got = Join(c.card_transcript);
    } else if (key == "last_applied_fill") {
      got = Hex(c.last_applied_fill);
    } else if (key == "hits_published") {
      got = std::to_string(c.hits_published);
    } else if (key == "hits_suppressed_while_disabled") {
      got = std::to_string(c.hits_suppressed_while_disabled);
    } else if (key == "frames_published") {
      got = std::to_string(c.frames_published);
    } else if (key == "frames_never_applied") {
      got = std::to_string(FramesNeverApplied(c));
    } else if (key == "insane_frames_rejected") {
      got = std::to_string(c.insane_frames_rejected);
    } else if (key == "dismiss_frames_applied") {
      got = std::to_string(c.dismiss_frames_applied);
    } else if (key == "dismiss_frames_failing_sanity") {
      got = std::to_string(c.dismiss_frames_failing_sanity);
    } else if (key == "inputs_forwarded") {
      got = std::to_string(c.inputs_forwarded);
    } else if (key == "inputs_ignored") {
      got = std::to_string(c.inputs_ignored);
    } else if (key == "bytes_written_while_disabled") {
      got = std::to_string(c.bytes_written_while_disabled);
    } else if (key == "cross_session_frames_applied") {
      got = std::to_string(c.cross_session_frames_applied);
    } else if (key == "v13_regions_untouched") {
      got = legacy_untouched ? "1" : "0";
    } else if (key == "tail_guard_intact") {
      got = mapping.TailGuardIntact() ? "1" : "0";
    } else if (key == "session_clean") {
      got = c.session_clean ? "1" : "0";
    } else {
      Check(false, "fixture 里出现未知 expect 键：" + key);
      continue;
    }
    Check(got == want, key + " 期望 " + want + "，实际 " + got);
  }

  if (g_failures != 0) {
    fprintf(stderr, "kirikiri lookup replay failures: %d\n", g_failures);
    return 1;
  }
  printf("kirikiri lookup replay ok\n");
  return 0;
}
