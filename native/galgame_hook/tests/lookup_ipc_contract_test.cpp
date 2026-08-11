// v14 游戏内查词区的**契约级**测试。
//
// 这块区的三条通道（hit / input / frame）是跨进程的，写侧在游戏进程里、读侧在 Hibiki
// 里，两边只靠 voice_hook_ipc.h 的寻址函数对齐。所以下面钉死的不是"某个 adapter 怎么
// 写"，而是**任何写侧/读侧都必须成立的结构性质**：
//
//   1. 各子区首尾相接、互不重叠、整区不越界，且每个子区都保持 8 字节对齐；
//   2. `IsLookupFrameSane` 是"按跨进程不可信的 width/height 盲拷"的**唯一闸门**——
//      每一条拒绝理由都要有自己的独立用例，否则某天有人删掉其中一条也没人发现；
//   3. `lookup_region_offset == 0`（旧会话 / 未分配）时访问器一律给 nullptr，而不是
//      拿 header 基址当区起点算出野指针；
//   4. v14 是**纯追加**：v13 及更早各区的偏移一个字节都不许被查词区影响。
//
// 与 text_lane_ipc_test.cpp 同一套做法：在进程内摆一块按真实布局排好的假共享内存，
// 直接跑契约头里的那份寻址实现（不复制一份到测试里）。

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "voice_hook_ipc.h"

namespace {

using fushi_voice_hook::HasLookupRegion;
using fushi_voice_hook::IsLookupFrameSane;
using fushi_voice_hook::kClipCount;
using fushi_voice_hook::kLookupBitmapBytes;
using fushi_voice_hook::kLookupFrameCount;
using fushi_voice_hook::kLookupFrameDismiss;
using fushi_voice_hook::kLookupInputSlotCount;
using fushi_voice_hook::kLookupLineBytes;
using fushi_voice_hook::kLoopbackMarkerCount;
using fushi_voice_hook::kSharedVersion;
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

// 按 injector 的真实布局摆一块共享内存：
//   [SharedHeader][音频环][文本区][clip 索引][loopback 环][标记表][线程预览区][查词区]
// 音频/loopback 环容量取小值——本测试一个字节都不碰它们，只是要让**查词区之前的所有区
// 都真实存在**，这样"查词区在最尾、前面各区偏移不受影响"才是被真的验证过的。
struct FakeMapping {
  static constexpr uint32_t kRingCapacity = 4096;
  static constexpr uint32_t kLoopbackCapacity = 4096;

  std::vector<uint8_t> bytes;
  uint64_t lookup_bytes = 0;
  uint64_t total_bytes = 0;

  explicit FakeMapping(bool with_lookup_region = true) {
    const uint64_t text_bytes =
        fushi_voice_hook::TextRegionBytes(kTextLaneCount, kTextLaneSlotCount);
    const uint64_t clip_bytes =
        static_cast<uint64_t>(kClipCount) * sizeof(VoiceClip);
    const uint64_t marker_bytes =
        static_cast<uint64_t>(kLoopbackMarkerCount) * sizeof(LoopbackMarker);
    const uint64_t preview_bytes =
        static_cast<uint64_t>(kThreadPreviewCount) * sizeof(ThreadPreviewSlot);
    lookup_bytes =
        with_lookup_region
            ? LookupRegionBytes(kLookupInputSlotCount, kLookupFrameCount,
                                kLookupBitmapBytes)
            : 0;
    total_bytes = sizeof(SharedHeader) + kRingCapacity + text_bytes +
                  clip_bytes + kLoopbackCapacity + marker_bytes +
                  preview_bytes + lookup_bytes;
    bytes.assign(static_cast<size_t>(total_bytes), 0);

    SharedHeader* h = header();
    h->magic = fushi_voice_hook::kSharedMagic;
    h->version = kSharedVersion;
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
    if (!with_lookup_region) return;
    h->lookup_region_offset =
        static_cast<uint32_t>(h->thread_preview_offset + preview_bytes);
    h->lookup_bitmap_bytes = kLookupBitmapBytes;
    h->lookup_frame_count = kLookupFrameCount;
    h->lookup_input_slot_count = kLookupInputSlotCount;
  }

  SharedHeader* header() {
    return reinterpret_cast<SharedHeader*>(bytes.data());
  }
  const SharedHeader* header() const {
    return reinterpret_cast<const SharedHeader*>(bytes.data());
  }
  // 任意指针相对 header 基址的字节偏移（越界与重叠判定统一用它，不再各算各的）。
  uint64_t OffsetOf(const void* pointer) const {
    return static_cast<uint64_t>(reinterpret_cast<const uint8_t*>(pointer) -
                                 bytes.data());
  }
};

// 一帧"本来就该被接受"的位图元数据：640x400 BGRA，紧凑 pitch，byte_len 自洽且远小于容量。
LookupFrame HealthyFrame() {
  LookupFrame frame = {};
  frame.seq = 7;
  frame.width = 640;
  frame.height = 400;
  frame.pitch = 640 * 4;
  frame.anchor_x = 120;
  frame.anchor_y = 64;
  frame.highlight_start = 3;
  frame.highlight_len = 2;
  frame.byte_len = frame.pitch * frame.height;
  frame.ready = 1;
  return frame;
}

// ── 1. 区布局：首尾相接、互不重叠、不越界、8 对齐 ────────────────────────────

void TestSubRegionsAreContiguousDisjointAndInBounds() {
  FakeMapping mapping;
  SharedHeader* h = mapping.header();

  const uint64_t region_start = h->lookup_region_offset;
  const uint64_t hit_at = mapping.OffsetOf(LookupHitOf(h));
  const uint64_t inputs_at = mapping.OffsetOf(LookupInputsOf(h));
  const uint64_t frames_at = mapping.OffsetOf(LookupFrameAt(h, 0));
  const uint64_t bitmaps_at = mapping.OffsetOf(LookupBitmapAt(h, 0));

  Check(hit_at == region_start, "hit 槽必须就是查词区起点");
  Check(inputs_at == hit_at + sizeof(LookupHitSlot),
        "输入环紧跟 hit 槽，中间不许有洞");
  Check(frames_at ==
            inputs_at + static_cast<uint64_t>(kLookupInputSlotCount) *
                            sizeof(LookupInputSlot),
        "帧元数据紧跟输入环");
  Check(bitmaps_at == frames_at + static_cast<uint64_t>(kLookupFrameCount) *
                                      sizeof(LookupFrame),
        "位图区紧跟帧元数据");

  // 整区尺寸函数与访问器算出的布局必须是同一个东西：injector 按前者分配、读写两侧按
  // 后者寻址，两者一旦漂开就是越界写。
  const uint64_t last_bitmap_end =
      mapping.OffsetOf(LookupBitmapAt(h, kLookupFrameCount - 1)) +
      h->lookup_bitmap_bytes;
  Check(last_bitmap_end - region_start ==
            LookupRegionBytes(kLookupInputSlotCount, kLookupFrameCount,
                              kLookupBitmapBytes),
        "访问器算出的整区跨度必须等于 LookupRegionBytes（分配与寻址同一份真值）");
  Check(last_bitmap_end <= mapping.total_bytes,
        "查词区最后一个字节仍在映射内");

  // 相邻子区互不重叠（上面的"紧跟"已蕴含，但这里按区间显式再判一次，避免某天有人
  // 把某个子区改成负跨度还让"紧跟"式断言碰巧成立）。
  const uint64_t hit_end = hit_at + sizeof(LookupHitSlot);
  const uint64_t inputs_end =
      inputs_at +
      static_cast<uint64_t>(kLookupInputSlotCount) * sizeof(LookupInputSlot);
  const uint64_t frames_end =
      frames_at +
      static_cast<uint64_t>(kLookupFrameCount) * sizeof(LookupFrame);
  Check(hit_end <= inputs_at && inputs_end <= frames_at &&
            frames_end <= bitmaps_at,
        "四个子区两两不重叠");
}

void TestEverySubRegionStaysEightAligned() {
  FakeMapping mapping;
  SharedHeader* h = mapping.header();
  Check(h->lookup_region_offset % 8 == 0, "查词区起点 8 对齐");
  Check(mapping.OffsetOf(LookupHitOf(h)) % 8 == 0, "hit 槽 8 对齐");
  Check(mapping.OffsetOf(LookupInputsOf(h)) % 8 == 0, "输入环 8 对齐");
  Check(mapping.OffsetOf(LookupFrameAt(h, 0)) % 8 == 0, "帧元数据 8 对齐");
  Check(mapping.OffsetOf(LookupBitmapAt(h, 0)) % 8 == 0, "位图区 8 对齐");
  // 逐槽也要对齐：跨进程 volatile uint64 seq 在 x86 上未对齐会撕裂。
  for (uint32_t i = 0; i < kLookupInputSlotCount; ++i) {
    Check(mapping.OffsetOf(&LookupInputsOf(h)[i]) % 8 == 0,
          "每个输入槽 8 对齐");
  }
  for (uint32_t i = 0; i < kLookupFrameCount; ++i) {
    Check(mapping.OffsetOf(LookupFrameAt(h, i)) % 8 == 0, "每个帧槽 8 对齐");
    Check(mapping.OffsetOf(LookupBitmapAt(h, i)) % 8 == 0,
          "每块位图缓冲 8 对齐");
  }
  Check(kLookupBitmapBytes % 8 == 0, "位图缓冲容量本身 8 对齐（否则第二块就歪了）");
  Check(kLookupLineBytes % 8 == 0, "整行台词缓冲 8 对齐");
}

void TestFrameAndBitmapIndexingIsBounded() {
  FakeMapping mapping;
  SharedHeader* h = mapping.header();
  const SharedHeader* ch = mapping.header();

  for (uint32_t i = 0; i + 1 < kLookupFrameCount; ++i) {
    Check(mapping.OffsetOf(LookupFrameAt(h, i + 1)) -
                  mapping.OffsetOf(LookupFrameAt(h, i)) ==
              sizeof(LookupFrame),
          "帧槽步长 = sizeof(LookupFrame)");
    Check(mapping.OffsetOf(LookupBitmapAt(h, i + 1)) -
                  mapping.OffsetOf(LookupBitmapAt(h, i)) ==
              h->lookup_bitmap_bytes,
          "位图步长 = lookup_bitmap_bytes（双缓冲不许互相踩）");
  }
  Check(LookupFrameAt(h, kLookupFrameCount) == nullptr,
        "越界帧下标必须给 nullptr");
  Check(LookupBitmapAt(h, kLookupFrameCount) == nullptr,
        "越界位图下标必须给 nullptr");
  Check(LookupFrameAt(ch, kLookupFrameCount) == nullptr,
        "const 重载同样挡越界帧下标");
  Check(LookupBitmapAt(ch, kLookupFrameCount) == nullptr,
        "const 重载同样挡越界位图下标");
  Check(LookupFrameAt(h, 0xFFFFFFFFu) == nullptr, "极端下标不得回绕成合法指针");
  Check(LookupBitmapAt(h, 0xFFFFFFFFu) == nullptr,
        "极端位图下标不得回绕成合法指针");
}

// ── 2. 旧会话：访问器给 nullptr，不给野指针 ──────────────────────────────────

void TestLegacySessionYieldsNullInsteadOfWildPointers() {
  // lookup_region_offset == 0：v13 及更早的 injector 建的映射，或本会话未分配查词区。
  // 此时 header 基址 + 0 是一个**看上去合法**的地址（正是 header 自己），如果访问器
  // 不挡，写 hit 槽就会把 header 本身覆盖掉。
  FakeMapping mapping;
  SharedHeader* h = mapping.header();
  h->lookup_region_offset = 0;
  const SharedHeader* ch = h;

  Check(!HasLookupRegion(h), "lookup_region_offset==0 即本会话无查词区");
  Check(LookupHitOf(h) == nullptr, "旧会话 hit 访问器给 nullptr");
  Check(LookupHitOf(ch) == nullptr, "旧会话 hit const 访问器给 nullptr");
  Check(LookupInputsOf(h) == nullptr, "旧会话输入环访问器给 nullptr");
  Check(LookupInputsOf(ch) == nullptr, "旧会话输入环 const 访问器给 nullptr");
  Check(LookupFrameAt(h, 0) == nullptr, "旧会话帧访问器给 nullptr");
  Check(LookupFrameAt(ch, 0) == nullptr, "旧会话帧 const 访问器给 nullptr");
  Check(LookupBitmapAt(h, 0) == nullptr, "旧会话位图访问器给 nullptr");
  Check(LookupBitmapAt(ch, 0) == nullptr, "旧会话位图 const 访问器给 nullptr");

  // 分工要说清：IsLookupFrameSane 只管"这一帧自身与容量自洽"，**不**管"这块区在不在"。
  // 旧会话下真正把拷贝挡住的是 LookupBitmapAt 给 nullptr。两道关缺一不可——只查帧不查
  // 区，就会拿着一个"看起来合法"的帧去写 header 基址。
  const LookupFrame frame = HealthyFrame();
  Check(IsLookupFrameSane(h, &frame),
        "帧闸门只看帧自身，不因为没有查词区就改口（分工必须清晰）");
  Check(LookupBitmapAt(h, 0) == nullptr,
        "旧会话下拷贝目标必须是 nullptr —— 这才是挡住写入的那道关");

  Check(!HasLookupRegion(nullptr), "header 为空即无查词区");
  Check(LookupHitOf(static_cast<SharedHeader*>(nullptr)) == nullptr,
        "header 为空时 hit 访问器给 nullptr");
  Check(LookupInputsOf(static_cast<SharedHeader*>(nullptr)) == nullptr,
        "header 为空时输入环访问器给 nullptr");
  Check(LookupFrameAt(static_cast<SharedHeader*>(nullptr), 0) == nullptr,
        "header 为空时帧访问器给 nullptr");
  Check(LookupBitmapAt(static_cast<SharedHeader*>(nullptr), 0) == nullptr,
        "header 为空时位图访问器给 nullptr");
}

// 三个冗余自洽字段任意一个为 0 都说明这块区没摆好；此时同样只能给 nullptr。
// 它们是"header 被半初始化 / 被旧版本 injector 建出来"的唯一可检信号。
void TestHalfInitialisedRegionIsTreatedAsAbsent() {
  struct Case {
    const char* what;
    uint32_t SharedHeader::*field;
  };
  const Case cases[] = {
      {"lookup_frame_count==0", &SharedHeader::lookup_frame_count},
      {"lookup_bitmap_bytes==0", &SharedHeader::lookup_bitmap_bytes},
      {"lookup_input_slot_count==0", &SharedHeader::lookup_input_slot_count},
  };
  for (const Case& c : cases) {
    FakeMapping mapping;
    SharedHeader* h = mapping.header();
    h->*(c.field) = 0;
    Check(!HasLookupRegion(h), std::string(c.what) + " 时必须判为无查词区");
    Check(LookupHitOf(h) == nullptr, std::string(c.what) + " 时 hit 给 nullptr");
    Check(LookupInputsOf(h) == nullptr,
          std::string(c.what) + " 时输入环给 nullptr");
    Check(LookupFrameAt(h, 0) == nullptr,
          std::string(c.what) + " 时帧给 nullptr");
    Check(LookupBitmapAt(h, 0) == nullptr,
          std::string(c.what) + " 时位图给 nullptr");
  }
  // 容量字段被清零时，帧闸门自己也会拒——这是它唯一与"区状态"有交集的地方。
  FakeMapping no_capacity;
  no_capacity.header()->lookup_bitmap_bytes = 0;
  const LookupFrame frame = HealthyFrame();
  Check(!IsLookupFrameSane(no_capacity.header(), &frame),
        "位图容量为 0 时任何帧都不该被判为可拷");
}

// ── 3. IsLookupFrameSane：越界写的唯一闸门 ─────────────────────────────────

// 每条拒绝理由一个独立用例，且**只**破坏那一条：其余字段保持自洽，否则测试挂了也说
// 不清是哪条规则在起作用（删掉一条规则时另一条会替它把用例撑绿 = 假绿）。
void TestFrameSanityRejectsEveryUntrustedShape() {
  FakeMapping mapping;
  SharedHeader* h = mapping.header();

  {
    const LookupFrame ok = HealthyFrame();
    Check(IsLookupFrameSane(h, &ok), "自洽的正常帧必须被接受");
  }
  {
    // 带行填充的 pitch（DXGI / WIC 常见）也必须接受——把它拒了就等于逼写侧自己重排像素。
    LookupFrame padded = HealthyFrame();
    padded.pitch = padded.width * 4 + 64;
    padded.byte_len = padded.pitch * padded.height;
    Check(IsLookupFrameSane(h, &padded), "pitch > width*4 的填充帧必须被接受");
  }
  {
    LookupFrame zero_width = HealthyFrame();
    zero_width.width = 0;
    zero_width.pitch = 0;
    zero_width.byte_len = 0;
    Check(!IsLookupFrameSane(h, &zero_width), "width==0 必须拒绝");
  }
  {
    LookupFrame zero_height = HealthyFrame();
    zero_height.height = 0;
    zero_height.byte_len = 0;
    Check(!IsLookupFrameSane(h, &zero_height), "height==0 必须拒绝");
  }
  {
    // 只让 width 超上界：height=1 使 pitch*height 仍远小于位图容量，从而排除
    // "其实是被容量规则挡下来的"这种假绿。
    LookupFrame huge_width = HealthyFrame();
    huge_width.width = 0x4001u;
    huge_width.height = 1;
    huge_width.pitch = huge_width.width * 4;
    huge_width.byte_len = huge_width.pitch * huge_width.height;
    Check(huge_width.byte_len < kLookupBitmapBytes,
          "构造前提：本用例的字节数没超容量（否则测的是别的规则）");
    Check(!IsLookupFrameSane(h, &huge_width), "width 超 0x4000 必须拒绝");
  }
  {
    LookupFrame huge_height = HealthyFrame();
    huge_height.width = 1;
    huge_height.height = 0x4001u;
    huge_height.pitch = 4;
    huge_height.byte_len = huge_height.pitch * huge_height.height;
    Check(huge_height.byte_len < kLookupBitmapBytes,
          "构造前提：本用例的字节数没超容量（否则测的是别的规则）");
    Check(!IsLookupFrameSane(h, &huge_height), "height 超 0x4000 必须拒绝");
  }
  {
    // pitch < width*4：按 width 逐行拷会读/写出行尾之外——经典越界形状。
    LookupFrame short_pitch = HealthyFrame();
    short_pitch.pitch = short_pitch.width * 4 - 1;
    short_pitch.byte_len = short_pitch.pitch * short_pitch.height;
    Check(!IsLookupFrameSane(h, &short_pitch), "pitch < width*4 必须拒绝");
  }
  {
    LookupFrame long_len = HealthyFrame();
    long_len.byte_len = long_len.pitch * long_len.height + 1;
    Check(!IsLookupFrameSane(h, &long_len),
          "byte_len > pitch*height 必须拒绝（多出来的那截没有像素来源）");
  }
  {
    LookupFrame short_len = HealthyFrame();
    short_len.byte_len = short_len.pitch * short_len.height - 1;
    Check(!IsLookupFrameSane(h, &short_len),
          "byte_len < pitch*height 必须拒绝（按 height 逐行拷会读过尾）");
  }
  {
    // 自洽但超容量：1024x1024 BGRA = 4MiB > 3MiB 单缓冲上限。
    LookupFrame too_big = HealthyFrame();
    too_big.width = 1024;
    too_big.height = 1024;
    too_big.pitch = too_big.width * 4;
    too_big.byte_len = too_big.pitch * too_big.height;
    Check(too_big.byte_len > kLookupBitmapBytes,
          "构造前提：本用例确实超了单缓冲容量");
    Check(too_big.width <= 0x4000u && too_big.height <= 0x4000u,
          "构造前提：宽高没超上界（否则测的是别的规则）");
    Check(!IsLookupFrameSane(h, &too_big), "byte_len 超单缓冲容量必须拒绝");
  }
  {
    const LookupFrame ok = HealthyFrame();
    Check(!IsLookupFrameSane(nullptr, &ok), "header 为空必须拒绝");
    Check(!IsLookupFrameSane(h, nullptr), "frame 为空必须拒绝");
  }
}

// 闸门的**意义**：过了闸门的帧，按 byte_len 整块拷进任意一块位图缓冲都不会越出查词区。
// 上面那些用例只是"某些形状被拒了"，这条才是"被留下的形状真的安全"。
void TestAcceptedFramesAlwaysFitInsideTheirBitmapSlot() {
  FakeMapping mapping;
  SharedHeader* h = mapping.header();
  const uint32_t widths[] = {1, 17, 640, 880, 0x4000u};
  const uint32_t heights[] = {1, 3, 400, 880};
  const uint32_t pitch_pads[] = {0, 4, 64};
  for (uint32_t w : widths) {
    for (uint32_t ht : heights) {
      for (uint32_t pad : pitch_pads) {
        LookupFrame frame = HealthyFrame();
        frame.width = w;
        frame.height = ht;
        frame.pitch = w * 4 + pad;
        frame.byte_len = frame.pitch * frame.height;
        if (!IsLookupFrameSane(h, &frame)) continue;
        for (uint32_t i = 0; i < kLookupFrameCount; ++i) {
          const uint64_t begin = mapping.OffsetOf(LookupBitmapAt(h, i));
          Check(begin + frame.byte_len <= mapping.total_bytes,
                "过闸门的帧按 byte_len 拷进任一缓冲都不得越出映射");
          Check(frame.byte_len <= h->lookup_bitmap_bytes,
                "过闸门的帧不得越出自己那块缓冲（否则会踩到下一块）");
        }
      }
    }
  }
}

// ── 3b. ShouldApplyLookupFrame：发布序 × hit_seq 的真值表 ────────────────────

// 两个序号各管一件事，混成一个就出过大事故（收卡整条不通，见 LookupFrame 注释）：
//   * `seq`     = 发布序，host 每投一帧 +1 —— 回答"这帧我处理过没有"；
//   * `hit_seq` = 回应哪次查询 —— 回答"用户是不是已经点了别的字"。
// 这张真值表就是把"两件事"钉成两件事。
void TestShouldApplyTruthTable() {
  struct Case {
    uint64_t frame_seq;
    uint64_t frame_hit_seq;
    uint64_t presented_seq;
    uint64_t current_hit_seq;
    bool expected;
    const char* what;
  };
  const uint64_t kPresented = 10;
  const uint64_t kCurrentHit = 5;
  const Case cases[] = {
      // 发布序更旧/相等：这帧已经处理过，hit_seq 再新也不重来。
      {9, 4, kPresented, kCurrentHit, false, "发布序更旧 + hit 更旧 → 拒"},
      {9, 5, kPresented, kCurrentHit, false, "发布序更旧 + hit 相等 → 拒"},
      {9, 6, kPresented, kCurrentHit, false, "发布序更旧 + hit 更新 → 拒"},
      {10, 5, kPresented, kCurrentHit, false, "发布序相等即已处理 → 拒"},
      // 发布序更新：再看它回应的那次查询有没有被作废。
      {11, 4, kPresented, kCurrentHit, false,
       "发布序更新但回应的是旧命中 → 拒（迟到帧不许顶掉新卡片）"},
      {11, 5, kPresented, kCurrentHit, true, "发布序更新 + 回应当前命中 → 应用"},
      {11, 6, kPresented, kCurrentHit, true,
       "发布序更新 + hit 比注入侧看到的还新（host 抢跑）→ 应用"},
  };
  for (const Case& c : cases) {
    Check(ShouldApplyLookupFrame(c.frame_seq, c.frame_hit_seq, c.presented_seq,
                                 c.current_hit_seq) == c.expected,
          c.what);
  }

  // 首帧：什么都还没处理过（presented=0），命中序从 1 起。
  Check(ShouldApplyLookupFrame(1, 1, 0, 1), "会话第一帧必须能应用");
  // 尚无命中（current_hit_seq=0）时 host 不该投帧，但真投了也不该被判为过期——
  // 过期与否只由这两个序号决定，别在这里塞第三种语义。
  Check(ShouldApplyLookupFrame(1, 0, 0, 0), "无命中时的帧不因 hit_seq=0 被判过期");
}

// 收卡整条不通的那个回归，用判据本身钉死：present 完立刻发的收卡帧必须过得去。
//
// 旧模型下 `seq` 一号两用，收卡只能复用被撤那张卡的 seq，于是"发布序不比已处理的新"
// 这一条把它自己挡在门外——补 0×0 分支也救不回来，因为帧压根进不了候选。
void TestDismissRightAfterPresentIsNotTreatedAsStale() {
  const uint64_t present_publish = 7;
  const uint64_t hit = 3;
  Check(ShouldApplyLookupFrame(present_publish, hit, present_publish - 1, hit),
        "构造前提：这次 present 本身是能被应用的");
  // host 收卡 = 领**下一个**发布序，hit_seq 仍指向被撤的那次查询。
  Check(ShouldApplyLookupFrame(present_publish + 1, hit, present_publish, hit),
        "紧跟 present 的收卡帧必须能被应用（收卡链曾经就死在这里）");
  // 反面：新命中来了之后，那张收卡帧作废，不许把新卡片收掉。
  Check(!ShouldApplyLookupFrame(present_publish + 1, hit, present_publish,
                                hit + 1),
        "陈旧的收卡帧不得收掉更新的卡片");
}

// 收卡帧靠 flags 自述，不靠"width==0 就是收卡"的魔法编码——后者与"host 投了张废帧"
// 在字节上完全一样。配套硬事实：收卡帧按定义过不了 IsLookupFrameSane，所以读侧**必须**
// 在那道校验之前先认 flags。
void TestDismissFrameIsFlagBornNotShapeInferred() {
  Check(kLookupFrameDismiss != 0, "收卡位不能是 0（0 位表达不了任何东西）");
  FakeMapping mapping;
  SharedHeader* h = mapping.header();
  LookupFrame dismiss = {};
  dismiss.seq = 3;
  dismiss.hit_seq = 2;
  dismiss.flags = kLookupFrameDismiss;
  dismiss.ready = 1;
  Check(!IsLookupFrameSane(h, &dismiss),
        "收卡帧没有像素，必然过不了尺寸闸门——故读侧必须先认 flags 再谈校验");
  LookupFrame junk = dismiss;
  junk.flags = 0;
  Check(!IsLookupFrameSane(h, &junk),
        "同样字节但没有收卡位 = host 投的废帧，只能被拒");
  Check((junk.flags & kLookupFrameDismiss) == 0,
        "废帧与收卡帧的唯一区别就是这个位，不是形状");
}

// ── 4. v14 是纯追加 ────────────────────────────────────────────────────────

void TestV14IsAPureAppendOverV13() {
  Check(kSharedVersion == 14, "本测试锁的是 v14 布局");

  // (a) 结构体层面：查词字段整体排在 v13 最后一个字段之后。中间插一个字段就会让所有
  //     v13 消费者读错位，而版本号又已经匹配、挡不住。
  const size_t last_v13_field =
      offsetof(SharedHeader, text_lane_overflow_count);
  const size_t first_v14_field = offsetof(SharedHeader, lookup_region_offset);
  Check(first_v14_field >= last_v13_field + sizeof(uint64_t),
        "查词字段必须整体排在 v13 末字段之后（纯追加）");
  Check(offsetof(SharedHeader, lookup_bitmap_bytes) > first_v14_field &&
            offsetof(SharedHeader, lookup_enabled) > first_v14_field &&
            offsetof(SharedHeader, lookup_diag) > first_v14_field,
        "所有 v14 字段都在查词区首字段之后");
  // v13 及更早的关键偏移逐个钉死，任何"顺手挪一下字段"都会红。
  Check(offsetof(SharedHeader, magic) == 0, "magic 必须仍在 0");
  Check(offsetof(SharedHeader, version) == 4, "version 必须仍在 4");
  Check(offsetof(SharedHeader, text_region_offset) < first_v14_field &&
            offsetof(SharedHeader, clip_region_offset) < first_v14_field &&
            offsetof(SharedHeader, loopback_ring_offset) < first_v14_field &&
            offsetof(SharedHeader, thread_preview_offset) < first_v14_field &&
            offsetof(SharedHeader, text_lane_count) < first_v14_field,
        "v13 区偏移字段一个都不许被挪到查词字段之后");

  // (b) 映射层面：同一套 v13 参数，带不带查词区算出的 v13 各区偏移必须逐字节相同。
  FakeMapping with_lookup(true);
  FakeMapping without_lookup(false);
  const SharedHeader* a = with_lookup.header();
  const SharedHeader* b = without_lookup.header();
  Check(a->text_region_offset == b->text_region_offset,
        "文本区偏移不受查词区影响");
  Check(a->clip_region_offset == b->clip_region_offset,
        "clip 区偏移不受查词区影响");
  Check(a->loopback_ring_offset == b->loopback_ring_offset,
        "loopback 环偏移不受查词区影响");
  Check(a->loopback_marker_offset == b->loopback_marker_offset,
        "loopback 标记表偏移不受查词区影响");
  Check(a->thread_preview_offset == b->thread_preview_offset,
        "线程预览区偏移不受查词区影响");
  Check(with_lookup.total_bytes - without_lookup.total_bytes ==
            LookupRegionBytes(kLookupInputSlotCount, kLookupFrameCount,
                              kLookupBitmapBytes),
        "带查词区只多出整区那么多字节，别的区一个字节没变");

  // (c) 查词区在**最尾**：它的起点不得早于线程预览区的终点。
  const uint64_t preview_end =
      static_cast<uint64_t>(a->thread_preview_offset) +
      static_cast<uint64_t>(a->thread_preview_slot_count) *
          sizeof(ThreadPreviewSlot);
  Check(a->lookup_region_offset >= preview_end,
        "查词区必须追加在所有 v13 区之后");
}

// 头里的冗余自洽字段必须与编译期常量一致——否则读侧按 header 值寻址、写侧按常量写，
// 会各算各的。
void TestHeaderMirrorsCompileTimeConstants() {
  FakeMapping mapping;
  const SharedHeader* h = mapping.header();
  Check(h->lookup_bitmap_bytes == kLookupBitmapBytes,
        "header 位图容量必须等于 kLookupBitmapBytes");
  Check(h->lookup_frame_count == kLookupFrameCount,
        "header 帧数必须等于 kLookupFrameCount");
  Check(h->lookup_input_slot_count == kLookupInputSlotCount,
        "header 输入槽数必须等于 kLookupInputSlotCount");
  Check(kLookupFrameCount >= 2, "位图必须至少双缓冲");
  Check(sizeof(LookupHitSlot) % 8 == 0, "hit 槽结构 8 对齐");
  // 帧结构随 v14 收卡改造从 48 字节长到 64（加了 hit_seq / flags / reserved2）。
  // 跨进程结构体不 8 对齐，双缓冲的第二块就会歪，且 volatile uint64 在 x86 上会撕裂。
  Check(sizeof(LookupFrame) % 8 == 0, "帧结构 8 对齐");
  Check(sizeof(LookupInputSlot) % 8 == 0, "输入槽结构 8 对齐");
}

}  // namespace

int main() {
  TestSubRegionsAreContiguousDisjointAndInBounds();
  TestEverySubRegionStaysEightAligned();
  TestFrameAndBitmapIndexingIsBounded();
  TestLegacySessionYieldsNullInsteadOfWildPointers();
  TestHalfInitialisedRegionIsTreatedAsAbsent();
  TestFrameSanityRejectsEveryUntrustedShape();
  TestShouldApplyTruthTable();
  TestDismissRightAfterPresentIsNotTreatedAsStale();
  TestDismissFrameIsFlagBornNotShapeInferred();
  TestAcceptedFramesAlwaysFitInsideTheirBitmapSlot();
  TestV14IsAPureAppendOverV13();
  TestHeaderMirrorsCompileTimeConstants();
  if (g_failures != 0) {
    fprintf(stderr, "lookup ipc contract test failures: %d\n", g_failures);
    return 1;
  }
  printf("lookup ipc contract test ok\n");
  return 0;
}
