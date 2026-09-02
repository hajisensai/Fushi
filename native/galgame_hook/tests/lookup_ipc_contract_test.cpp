// v19 游戏内查词区的**契约级**测试。
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
//   4. v14 查词区仍是对 v13 的**纯追加**布局；v15 又只在 v14 头尾追加
//      lookup_frame_applied_seq，任何既有字段一个字节都不许挪；
//   5. capture-suppress 有独占的精确 flags 身份，普通 present/dismiss/highlight 或混合位
//      不能冒充一笔可确认的截图抑制。
//
// 与 text_lane_ipc_test.cpp 同一套做法：在进程内摆一块按真实布局排好的假共享内存，
// 直接跑契约头里的那份寻址实现（不复制一份到测试里）。

// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

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
using fushi_voice_hook::kLookupFrameCaptureSuppress;
using fushi_voice_hook::kLookupFrameDismiss;
using fushi_voice_hook::kLookupFrameHighlightOnly;
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
    // 自洽但超容量：宽高都在 0x4000 上界内，唯一越界的是总字节数。
    //
    // 尺寸**从 kLookupBitmapBytes 推导**，不写死。容量抬过一次（3MiB→8MiB），
    // 原来写死的 1024x1024（4MiB）当场变成"没超容量"，这条用例于是静默失去意义
    // ——构造前提断言先红，而它测的那条规则根本没被执行到。
    LookupFrame too_big = HealthyFrame();
    too_big.width = 2048;
    too_big.pitch = too_big.width * 4;
    too_big.height = kLookupBitmapBytes / too_big.pitch + 1;
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
    uint32_t frame_flags;
    uint64_t presented_seq;
    uint64_t current_any_hit_seq;
    uint64_t current_submit_hit_seq;
    bool expected;
    const char* what;
  };
  const uint64_t kPresented = 10;
  const uint64_t kCurrentAnyHit = 6;
  const uint64_t kCurrentSubmitHit = 5;
  const Case cases[] = {
      // 发布序更旧/相等：fence 命中也不重来。
      {9, 5, 0, kPresented, kCurrentAnyHit, kCurrentSubmitHit, false,
       "卡片命中 submit fence，但发布序更旧 → 拒"},
      {10, 6, kLookupFrameHighlightOnly, kPresented, kCurrentAnyHit,
       kCurrentSubmitHit, false, "高亮命中 any fence，但发布序相等 → 拒"},
      // submit B=5 之后只有 hover C=6：卡片仍回应 B，必须接受。
      {11, 5, 0, kPresented, kCurrentAnyHit, kCurrentSubmitHit, true,
       "submit B → hover C → present B 仍应用 submit fence"},
      {11, 5, kLookupFrameDismiss, kPresented, kCurrentAnyHit,
       kCurrentSubmitHit, true,
       "submit B 无结果后 dismiss(B) 不得被 hover C 拦截"},
      // highlight-only 只看 any fence，旧悬停和未来序都必须拒绝。
      {11, 6, kLookupFrameHighlightOnly, kPresented, kCurrentAnyHit,
       kCurrentSubmitHit, true, "highlight-only 严格命中 any fence → 应用"},
      {11, 5, kLookupFrameHighlightOnly, kPresented, kCurrentAnyHit,
       kCurrentSubmitHit, false, "旧 hover 高亮不得覆盖当前 hover"},
      {11, 7, kLookupFrameHighlightOnly, kPresented, kCurrentAnyHit,
       kCurrentSubmitHit, false, "尚未发布的 hover 高亮不得抢跑"},
      // submit D=7 后，B=5 的卡片/收卡都作废。
      {11, 5, 0, kPresented, 7, 7, false,
       "submit D 后迟到的 present B 必须拒绝"},
      {11, 5, kLookupFrameDismiss, kPresented, 7, 7, false,
       "submit D 后迟到的 dismiss(B) 不得收掉 D"},
  };
  for (const Case& c : cases) {
    Check(ShouldApplyLookupFrame(c.frame_seq, c.frame_hit_seq, c.frame_flags,
                                 c.presented_seq, c.current_any_hit_seq,
                                 c.current_submit_hit_seq) == c.expected,
          c.what);
  }

  Check(ShouldApplyLookupFrame(1, 1, 0, 0, 1, 1),
        "会话第一张 submit 卡必须能应用");
}

// 收卡整条不通的那个回归，用判据本身钉死：present 完立刻发的收卡帧必须过得去。
//
// 旧模型下 `seq` 一号两用，收卡只能复用被撤那张卡的 seq，于是"发布序不比已处理的新"
// 这一条把它自己挡在门外——补 0×0 分支也救不回来，因为帧压根进不了候选。
void TestDismissRightAfterPresentIsNotTreatedAsStale() {
  const uint64_t present_publish = 7;
  const uint64_t hit = 3;
  Check(ShouldApplyLookupFrame(present_publish, hit, 0, present_publish - 1,
                               hit, hit),
        "构造前提：这次 present 本身是能被应用的");
  // host 收卡 = 领**下一个**发布序，hit_seq 仍指向被撤的那次查询。
  Check(ShouldApplyLookupFrame(present_publish + 1, hit, kLookupFrameDismiss,
                               present_publish, hit, hit),
        "紧跟 present 的收卡帧必须能被应用（收卡链曾经就死在这里）");
  // 反面：新命中来了之后，那张收卡帧作废，不许把新卡片收掉。
  Check(!ShouldApplyLookupFrame(present_publish + 1, hit,
                                kLookupFrameDismiss, present_publish, hit + 1,
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

// 截图抑制同样是无像素控制帧，但它不能按“含有某个位”识别。若 dismiss/highlight 与
// suppress 混合后也能命中，普通控制帧就可能排入 applied-seq 确认链，host 会在 popup
// 仍可见时误以为窗口已经干净。
void TestCaptureSuppressHasExactControlIdentity() {
  Check(kLookupFrameCaptureSuppress == 0x00000004u,
        "v15 capture-suppress 的 wire flag 必须锁在 0x4");
  Check((kLookupFrameCaptureSuppress & kLookupFrameDismiss) == 0,
        "capture-suppress 与 dismiss 必须是互斥位");
  Check((kLookupFrameCaptureSuppress & kLookupFrameHighlightOnly) == 0,
        "capture-suppress 与 highlight-only 必须是互斥位");

  const uint32_t ordinary_or_mixed_flags[] = {
      0,
      kLookupFrameDismiss,
      kLookupFrameHighlightOnly,
      kLookupFrameDismiss | kLookupFrameCaptureSuppress,
      kLookupFrameHighlightOnly | kLookupFrameCaptureSuppress,
      kLookupFrameDismiss | kLookupFrameHighlightOnly |
          kLookupFrameCaptureSuppress,
  };
  for (const uint32_t flags : ordinary_or_mixed_flags) {
    Check(flags != kLookupFrameCaptureSuppress,
          "只有 exact CaptureSuppress 能进入截图确认链；普通/混合帧不得冒充 ack");
  }
}

// ── 4. v14/v15/v16 都是纯追加 ───────────────────────────────────────────────

void TestV14LookupRegionIsPureAppendOverV13() {
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

void TestV16V17AndV19OnlyAppendOverV15() {
  Check(kSharedVersion == 21,
        "本测试锁的是 v21 契约（native input admission 独立）");

  // v14 的最后一个字段是 lookup_diag。v15 只能紧随其后追加一个 64 位 applied seq；
  // 把字段插进 v14 中间，或在 applied seq 后再偷偷长出别的字段，都必须判红。
  const size_t last_v14_field = offsetof(SharedHeader, lookup_diag);
  const size_t only_v15_field =
      offsetof(SharedHeader, lookup_frame_applied_seq);
  Check(only_v15_field == last_v14_field + sizeof(uint32_t),
        "v15 applied seq 必须紧跟 v14 末字段，不能移动或填改既有查词字段");
  Check(only_v15_field % alignof(uint64_t) == 0,
        "v15 applied seq 必须保持 8 字节对齐");
  const size_t first_v16_field =
      offsetof(SharedHeader, native_loopback_requested);
  Check(first_v16_field == only_v15_field + sizeof(uint64_t),
        "v16 policy 必须紧跟 v15 applied seq，不能移动任何既有字段");
  Check(offsetof(SharedHeader, native_loopback_request_seq) ==
            first_v16_field + sizeof(uint32_t) &&
            offsetof(SharedHeader, native_loopback_state) ==
                first_v16_field + 2 * sizeof(uint32_t) &&
            offsetof(SharedHeader, native_loopback_applied_seq) ==
                first_v16_field + 3 * sizeof(uint32_t),
        "v16 四个 32 位 policy word 必须按契约连续尾追加");
  // v17 只在 v16 末尾再追加驻留 hook DLL 摘要（定长 char 数组），前面各字段偏移不动。
  const size_t only_v17_field = offsetof(SharedHeader, hook_module_sha256);
  Check(only_v17_field ==
            offsetof(SharedHeader, native_loopback_applied_seq) +
                sizeof(uint32_t),
        "v17 摘要必须紧跟 v16 末字段，不能移动任何既有字段");
  // v19 从 v17 摘要后按字段自然对齐纯追加；v18 只改 keys 语义，没有新字段。
  const size_t first_v19_field =
      offsetof(SharedHeader, lookup_geometry_active_kind);
  const size_t v17_payload_end =
      only_v17_field + fushi_voice_hook::kHookModuleDigestChars;
  Check(first_v19_field == (v17_payload_end + 3u) / 4u * 4u,
        "v19 几何状态必须紧跟 v17 摘要的自然对齐尾部");
  const size_t geometry_text_generation =
      (first_v19_field + 4u * sizeof(uint32_t) + 7u) / 8u * 8u;
  Check(offsetof(SharedHeader, lookup_geometry_active_id) ==
            first_v19_field + 4u &&
            offsetof(SharedHeader, lookup_geometry_status) ==
                first_v19_field + 8u &&
            offsetof(SharedHeader, lookup_geometry_text_generation) ==
                geometry_text_generation &&
            offsetof(SharedHeader, lookup_geometry_generation) ==
                geometry_text_generation + 8u,
        "v19 几何 active/status/generation 字段顺序固定");
  const size_t shield_begin =
      offsetof(SharedHeader, lookup_shield_request_seq);
  Check(shield_begin == geometry_text_generation + 16u,
        "v19 shield 控制必须紧跟几何状态");
  Check(offsetof(SharedHeader, lookup_shield_owner_kind) == shield_begin + 4u &&
            offsetof(SharedHeader, lookup_shield_target_hwnd) ==
                shield_begin + 8u &&
            offsetof(SharedHeader, lookup_shield_transaction_id) ==
                shield_begin + 16u &&
            offsetof(SharedHeader, lookup_shield_active_buttons) ==
                shield_begin + 24u &&
            offsetof(SharedHeader, lookup_shield_required_mask) ==
                shield_begin + 32u &&
            offsetof(SharedHeader, lookup_shield_applied_seq) ==
                shield_begin + 56u,
        "v19 shield request/status 字段顺序固定");
  const size_t geometry_admission_begin =
      offsetof(SharedHeader, lookup_geometry_admission_mode);
  Check(geometry_admission_begin ==
            offsetof(SharedHeader, lookup_shield_reserved2) + 4u &&
            offsetof(SharedHeader, lookup_geometry_admission_flags) ==
                geometry_admission_begin + 4u &&
            offsetof(SharedHeader, lookup_geometry_admission_request_seq) ==
                geometry_admission_begin + 8u &&
            offsetof(SharedHeader, lookup_geometry_admission_applied_seq) ==
                geometry_admission_begin + 12u,
        "v19 geometry admission 必须纯追加在 shield 尾部，且 x86/x64 同步长");
  // 合版后几何区不再是结构体最后一组：develop 的准入区（lookup_admission /
  // _seq / _executable_sha256）排在它之后。所以这里改判「顺序」而不是「我是最后一个」——
  // 几何必须纯追加在 shield 之后，准入必须纯追加在几何之后，谁都不许插进已有区。
  // 「末尾只有 8 字节对齐填充」这条整体性断言由 TestV19AdmissionIsPureAppendOverV17
  // 按真正的末尾字段 lookup_executable_sha256 负责，两处不重复。
  Check(offsetof(SharedHeader, lookup_admission) >=
            offsetof(SharedHeader, lookup_geometry_admission_applied_seq) + 4u,
        "准入区必须追加在几何区之后，不得插进几何区中间");
}

void TestV21GeometryAdmissionPublication() {
  SharedHeader h = {};
  Check(!fushi_voice_hook::ReadLookupGeometryAdmission(&h).valid,
        "seq=0 的 geometry admission 不得当成已发布请求");
  const uint32_t first =
      fushi_voice_hook::PublishLookupGeometryAdmission(
          &h, fushi_voice_hook::kLookupGeometryAdmissionAuto, true, false);
  const auto auto_attached =
      fushi_voice_hook::ReadLookupGeometryAdmission(&h);
  Check(first == 1u && auto_attached.valid && auto_attached.seq == first &&
            auto_attached.mode ==
                fushi_voice_hook::kLookupGeometryAdmissionAuto &&
            auto_attached.attached_ready(),
        "auto+attached-ready payload 必须 coherent round-trip");
  Check(fushi_voice_hook::PublishLookupGeometryAdmission(
            &h, fushi_voice_hook::kLookupGeometryAdmissionAuto, true, false) ==
            first,
        "重复 geometry admission 必须幂等，不制造假代际");
  const uint32_t second =
      fushi_voice_hook::PublishLookupGeometryAdmission(
          &h, fushi_voice_hook::kLookupGeometryAdmissionNativeOnly, false,
          false);
  const auto native_only =
      fushi_voice_hook::ReadLookupGeometryAdmission(&h);
  Check(second == 2u && native_only.valid &&
            native_only.mode ==
                fushi_voice_hook::kLookupGeometryAdmissionNativeOnly &&
            !native_only.attached_ready(),
        "owner policy edge 必须产生新 request generation");
  fushi_voice_hook::AtomicStoreShared32(
      &h.lookup_geometry_admission_request_seq,
      fushi_voice_hook::kLookupGeometryAdmissionWriteInProgress | second);
  Check(!fushi_voice_hook::ReadLookupGeometryAdmission(&h).valid,
        "writer-held geometry admission 不得被读成 disable/半份 payload");
  fushi_voice_hook::AtomicStoreShared32(
      &h.lookup_geometry_admission_request_seq, second);
  Check(fushi_voice_hook::PublishLookupGeometryAdmission(
            &h, 99u, true, false) == 0 &&
            fushi_voice_hook::ReadLookupGeometryAdmission(&h).mode ==
                fushi_voice_hook::kLookupGeometryAdmissionNativeOnly,
        "非法 admission mode 必须拒绝且不改稳定请求");
}

void TestV19ShieldPublicationAndVerifiedGate() {
  SharedHeader h = {};
  const uint32_t request_seq = fushi_voice_hook::PublishLookupShieldRequest(
      &h, fushi_voice_hook::kLookupShieldOwnerAttachedGlyph, 0x1234u, 9u,
      fushi_voice_hook::kLookupShieldButtonLeft, false);
  Check(request_seq == 1u, "fresh shield request 必须从 seq=1 发布");
  const auto request = fushi_voice_hook::ReadLookupShieldRequest(&h);
  Check(request.valid && request.seq == request_seq &&
            request.owner_kind ==
                fushi_voice_hook::kLookupShieldOwnerAttachedGlyph &&
            request.target_hwnd == 0x1234u && request.transaction_id == 9u &&
            request.active_buttons ==
                fushi_voice_hook::kLookupShieldButtonLeft &&
            !request.allow_risk,
        "shield request payload/seq 必须 coherent round-trip");

  fushi_voice_hook::AtomicStoreShared32(
      &h.lookup_shield_request_seq,
      request_seq | fushi_voice_hook::kLookupShieldRequestWriteInProgress);
  Check(!fushi_voice_hook::ReadLookupShieldRequest(&h).valid,
        "writer-held shield payload 必须不可读；generic risk 路径不能把半份请求当 verified");
  fushi_voice_hook::AtomicStoreShared32(&h.lookup_shield_request_seq,
                                        request_seq);

  fushi_voice_hook::LookupShieldStatusPublication status;
  status.required_mask =
      fushi_voice_hook::kLookupShieldSurfaceLowLevelMouse |
      fushi_voice_hook::kLookupShieldSurfaceDirectInputImmediate;
  status.ready_mask = status.required_mask;
  status.observed_mask = status.required_mask;
  status.status_flags = fushi_voice_hook::kLookupShieldStatusVerified;
  Check(fushi_voice_hook::PublishLookupShieldStatus(&h, request, status),
        "完整 ready 且无风险/故障时必须能确认状态");
  Check(h.lookup_shield_applied_seq == request_seq &&
            (h.lookup_shield_status_flags &
             fushi_voice_hook::kLookupShieldStatusVerified) != 0,
        "verified 只能随 applied_seq 最后确认");

  status.status_flags = fushi_voice_hook::kLookupShieldStatusVerified |
                        fushi_voice_hook::kLookupShieldStatusRiskAllowed;
  const uint32_t explicit_risk =
      fushi_voice_hook::NormalizeLookupShieldStatusFlags(request, status);
  Check((explicit_risk & fushi_voice_hook::kLookupShieldStatusVerified) == 0 &&
            (explicit_risk & fushi_voice_hook::kLookupShieldStatusPartial) != 0 &&
            (explicit_risk &
             fushi_voice_hook::kLookupShieldStatusRiskAllowed) != 0,
        "显式 risk 状态同样不得与 verified 并存");

  const uint32_t mismatched_seq =
      fushi_voice_hook::PublishLookupShieldRequest(
          &h, fushi_voice_hook::kLookupShieldOwnerAttachedGlyph, 0x1234u,
          91u, fushi_voice_hook::kLookupShieldButtonLeft, false);
  const auto mismatched = fushi_voice_hook::ReadLookupShieldRequest(&h);
  status.ready_mask =
      status.required_mask | fushi_voice_hook::kLookupShieldSurfaceRawInputData;
  status.status_flags = fushi_voice_hook::kLookupShieldStatusVerified;
  Check(mismatched_seq == 2u &&
            fushi_voice_hook::PublishLookupShieldStatus(&h, mismatched,
                                                        status),
        "mismatched shield masks 仍需 ack");
  Check((h.lookup_shield_status_flags &
         fushi_voice_hook::kLookupShieldStatusVerified) == 0 &&
            (h.lookup_shield_status_flags &
             fushi_voice_hook::kLookupShieldStatusPartial) != 0,
        "required/ready 不完全相等时不得发布 verified");

  const uint32_t risky_seq = fushi_voice_hook::PublishLookupShieldRequest(
      &h, fushi_voice_hook::kLookupShieldOwnerAttachedGlyph, 0x1234u, 10u,
      fushi_voice_hook::kLookupShieldButtonLeft, true);
  const auto risky = fushi_voice_hook::ReadLookupShieldRequest(&h);
  Check(risky_seq == 3u && risky.valid && risky.allow_risk,
        "风险授权必须形成新 request generation");
  status.ready_mask = status.required_mask;
  status.fault_mask = 0;
  status.status_flags = fushi_voice_hook::kLookupShieldStatusVerified;
  Check(fushi_voice_hook::PublishLookupShieldStatus(&h, risky, status),
        "风险状态仍需 ack");
  Check((h.lookup_shield_status_flags &
         fushi_voice_hook::kLookupShieldStatusVerified) == 0 &&
            (h.lookup_shield_status_flags &
             fushi_voice_hook::kLookupShieldStatusPartial) != 0 &&
            (h.lookup_shield_status_flags &
             fushi_voice_hook::kLookupShieldStatusRiskAllowed) != 0,
        "allowRisk 路径绝不能冒充 verified");

  const uint32_t fault_seq = fushi_voice_hook::PublishLookupShieldRequest(
      &h, fushi_voice_hook::kLookupShieldOwnerNativeGlyph, 0x1234u, 11u,
      fushi_voice_hook::kLookupShieldButtonLeft, false);
  const auto fault_request = fushi_voice_hook::ReadLookupShieldRequest(&h);
  status.fault_mask =
      fushi_voice_hook::kLookupShieldSurfaceDirectInputImmediate;
  status.status_flags = fushi_voice_hook::kLookupShieldStatusVerified;
  Check(fault_seq == 4u && fushi_voice_hook::PublishLookupShieldStatus(
                                &h, fault_request, status),
        "fault 状态必须可确认");
  Check((h.lookup_shield_status_flags &
         fushi_voice_hook::kLookupShieldStatusFaulted) != 0 &&
            (h.lookup_shield_status_flags &
             fushi_voice_hook::kLookupShieldStatusVerified) == 0,
        "任一 fault 面必须压过 verified");
}

void TestV19AttachedGeometryOwnershipSnapshot() {
  SharedHeader h = {};
  h.lookup_geometry_active_kind =
      fushi_voice_hook::kLookupGeometryProviderAttachedCalibrated;
  h.lookup_geometry_active_id =
      fushi_voice_hook::kLookupGeometryProviderIdAttachedCalibrated;
  h.lookup_geometry_status = fushi_voice_hook::kLookupGeometryStatusReady;
  Check(fushi_voice_hook::LookupGeometryAttachedProviderOwns(&h),
        "attached Ready 必须在首个 hit 前拥有 geometry");

  h.lookup_geometry_status = fushi_voice_hook::kLookupGeometryStatusActive;
  Check(!fushi_voice_hook::LookupGeometryAttachedProviderOwns(&h),
        "attached Active 缺失 text/geometry generation 必须拒绝");
  h.lookup_geometry_text_generation = 7;
  h.lookup_geometry_generation = 9;
  Check(fushi_voice_hook::LookupGeometryAttachedProviderOwns(&h),
        "完整 attached Active generation 必须可拥有 geometry");

  h.lookup_geometry_active_kind =
      fushi_voice_hook::kLookupGeometryProviderRuntimeLayout;
  h.lookup_geometry_active_id =
      fushi_voice_hook::kLookupGeometryProviderIdRenpy;
  h.lookup_geometry_status = fushi_voice_hook::kLookupGeometryStatusReady;
  h.lookup_geometry_text_generation = 0;
  h.lookup_geometry_generation = 0;
  Check(!fushi_voice_hook::LookupGeometryAttachedProviderOwns(&h),
        "native provider 抢占后旧 attached snapshot 不得继续拥有点击");
}

// v19 只在 v17 摘要之后追加查词准入三字段，前面一个偏移都不许动。
void TestV19AdmissionIsPureAppendOverV17() {
  const size_t v17_end =
      offsetof(SharedHeader, hook_module_sha256) +
      fushi_voice_hook::kHookModuleDigestChars;
  const size_t admission = offsetof(SharedHeader, lookup_admission);
  Check(admission >= v17_end,
        "v19 准入字段必须追加在 v17 摘要之后，不能插进既有布局");
  // 这条不是形式主义：admission / admission_seq 全程走 Interlocked（AtomicLoadShared32
  // 等），而 Interlocked 系在**未对齐地址上是未定义行为**。前一个字段是 65 字节的奇数长
  // char 数组，一旦有人把 pack(8) 改成 pack(1)，这里就会静默变成未对齐的原子操作——
  // 症状是跨进程偶发读到撕裂值，不会报错。
  Check(admission % 4 == 0, "lookup_admission 必须 4 字节对齐（Interlocked 前提）");
  Check(offsetof(SharedHeader, lookup_admission_seq) ==
            admission + sizeof(uint32_t),
        "admission_seq 必须紧跟 admission");
  Check(offsetof(SharedHeader, lookup_admission_seq) % 4 == 0,
        "lookup_admission_seq 必须 4 字节对齐（Interlocked 前提）");
  Check(offsetof(SharedHeader, lookup_executable_sha256) ==
            offsetof(SharedHeader, lookup_admission_seq) + sizeof(uint32_t),
        "exe 摘要必须紧跟 admission_seq");
  Check(sizeof(SharedHeader) ==
            ((offsetof(SharedHeader, lookup_executable_sha256) +
              fushi_voice_hook::kHookModuleDigestChars + 7u) /
             8u) * 8u,
        "v19 末尾除 8 字节对齐填充外不得混入其他字段");
}

// 准入的读写往返。这些性质全都是「UI 会不会误导用户」的直接决定因素，不是内部细节。
void TestAdmissionRoundTrip() {
  FakeMapping mapping;
  SharedHeader* h = mapping.header();

  // (a) 从未上报过（seq==0）必须读成 Unknown。绝不能读成 EngineUnsupported——
  //     helper 刚起来的那几百毫秒里，"还不知道"被当成"不支持"就是稳定误报。
  uint32_t seq = 0xffffffffu;
  fushi_voice_hook::LookupAdmissionReport read =
      fushi_voice_hook::ReadLookupAdmission(h, &seq);
  Check(seq == 0, "未上报时 seq 必须是 0");
  Check(read.state == fushi_voice_hook::kLookupAdmissionUnknown,
        "未上报必须读成 Unknown，不得读成 EngineUnsupported");

  // (b) 正常往返：状态 + 摘要都要原样回来。
  fushi_voice_hook::LookupAdmissionReport rejected;
  rejected.state = fushi_voice_hook::kLookupAdmissionIdentityRejected;
  const char* digest =
      "005e71107ed70e662c41cb526879cdcf0b9486e067c0e5a306308688c17409ed";
  memcpy(rejected.executable_sha256, digest, strlen(digest) + 1);
  Check(fushi_voice_hook::PublishLookupAdmission(h, rejected),
        "首次发布必须返回 true（内容确实变了）");
  read = fushi_voice_hook::ReadLookupAdmission(h, &seq);
  Check(seq == 1, "首次发布后 seq 必须是 1");
  Check(read.state == fushi_voice_hook::kLookupAdmissionIdentityRejected,
        "状态必须原样回来");
  Check(strcmp(read.executable_sha256, digest) == 0,
        "exe 摘要必须原样回来——用户就是靠它报版本的");

  // (c) 幂等：内容没变时不得推进 seq。registry 每 16ms Poll 一次，无脑推 seq 会让
  //     host 每轮都当成新事件刷 UI。
  Check(!fushi_voice_hook::PublishLookupAdmission(h, rejected),
        "内容未变时必须返回 false");
  fushi_voice_hook::ReadLookupAdmission(h, &seq);
  Check(seq == 1, "内容未变时 seq 不得推进");

  // (d) 状态变化必须推进 seq。
  fushi_voice_hook::LookupAdmissionReport installed;
  installed.state = fushi_voice_hook::kLookupAdmissionSensorInstalled;
  Check(fushi_voice_hook::PublishLookupAdmission(h, installed),
        "状态变化必须返回 true");
  read = fushi_voice_hook::ReadLookupAdmission(h, &seq);
  Check(seq == 2, "状态变化必须推进 seq");
  Check(read.state == fushi_voice_hook::kLookupAdmissionSensorInstalled,
        "新状态必须生效");
  Check(read.executable_sha256[0] == '\0',
        "装上之后不再带摘要——那是给身份被拒的用户看的");

  // (e) 本构建不认识的状态值必须落回 Unknown，绝不猜。写侧可能是更新的 helper。
  fushi_voice_hook::AtomicStoreShared32(&h->lookup_admission, 99u);
  read = fushi_voice_hook::ReadLookupAdmission(h, &seq);
  Check(read.state == fushi_voice_hook::kLookupAdmissionUnknown,
        "未知状态值必须落回 Unknown");

  // (f) 摘要字段全是非 NUL 字节时读侧必须有界收尾，不得越界读。
  fushi_voice_hook::AtomicStoreShared32(
      &h->lookup_admission, fushi_voice_hook::kLookupAdmissionIdentityRejected);
  memset(const_cast<char*>(h->lookup_executable_sha256), 'a',
         fushi_voice_hook::kHookModuleDigestChars);
  read = fushi_voice_hook::ReadLookupAdmission(h, &seq);
  Check(strlen(read.executable_sha256) ==
            fushi_voice_hook::kHookModuleDigestChars - 1,
        "无 NUL 的摘要必须被有界截断，不得越界");
}

// 摘要格式化：各 profile 做 hash 准入时已经算出 32 字节摘要，这里只负责变成十六进制。
void TestSha256HexFormatting() {
  const uint8_t digest[32] = {0x00, 0x5e, 0x71, 0x10, 0x7e, 0xd7, 0x0e, 0x66,
                              0x2c, 0x41, 0xcb, 0x52, 0x68, 0x79, 0xcd, 0xcf,
                              0x0b, 0x94, 0x86, 0xe0, 0x67, 0xc0, 0xe5, 0xa3,
                              0x06, 0x30, 0x86, 0x88, 0xc1, 0x74, 0x09, 0xed};
  char out[fushi_voice_hook::kHookModuleDigestChars] = {};
  fushi_voice_hook::FormatSha256Hex(digest, sizeof(digest), out, sizeof(out));
  Check(strcmp(out,
               "005e71107ed70e662c41cb526879cdcf0b9486e067c0e5a306308688c17409ed") == 0,
        "摘要必须格式化成小写十六进制，前导零不得吞掉");
  // 缓冲不够时必须给空串而不是截断的半个摘要——半个摘要比没有更糟，用户会照着报错版本。
  char small[8] = {'x'};
  fushi_voice_hook::FormatSha256Hex(digest, sizeof(digest), small, sizeof(small));
  Check(small[0] == '\0', "缓冲不足必须留空串，不得输出截断摘要");
  // 长度不对的摘要一律拒绝。
  char out2[fushi_voice_hook::kHookModuleDigestChars] = {'x'};
  fushi_voice_hook::FormatSha256Hex(digest, 16, out2, sizeof(out2));
  Check(out2[0] == '\0', "非 32 字节摘要必须拒绝");
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
  Check(offsetof(LookupHitSlot, provider_kind) == sizeof(uint64_t),
        "v19 provider kind 必须紧跟 hit seq");
  Check(offsetof(LookupHitSlot, source_length) >
            offsetof(LookupHitSlot, char_index) &&
            offsetof(LookupHitSlot, text_generation) <
                offsetof(LookupHitSlot, glyph_x),
        "v19 source span 与 generation 必须属于 hit payload");
  // 帧结构随 v14 收卡改造从 48 字节长到 64（加了 hit_seq / flags / reserved2）。
  // v15 只在 SharedHeader 末尾追加 ack，不能顺手改 LookupFrame 的跨进程步长。
  Check(sizeof(LookupFrame) == 64, "v15 不得改变 v14 的 64 字节帧结构");
  // 跨进程结构体不 8 对齐，双缓冲的第二块就会歪，且 volatile uint64 在 x86 上会撕裂。
  Check(sizeof(LookupFrame) % 8 == 0, "帧结构 8 对齐");
  Check(sizeof(LookupInputSlot) % 8 == 0, "输入槽结构 8 对齐");
  Check(sizeof(LookupInputSlot) == 32, "输入槽 ABI 尺寸保持 32 字节");
  Check(fushi_voice_hook::kLookupInputDismissOutside == 5,
        "位图卡外关闭控制 kind 固定为 5");
  Check(fushi_voice_hook::kLookupInputVirtualKeyLeftButton == 0x0001u,
        "输入 keys 的 bit0 固定表示 WebView2 左键");
  Check(fushi_voice_hook::kLookupInputVirtualKeyShift == 0x0004u,
        "输入 keys 的 Shift 固定为 WebView2 bit2，不得压成 bit0");
  Check(fushi_voice_hook::kLookupInputVirtualKeyControl == 0x0008u,
        "输入 keys 的 Control 固定为 WebView2 bit3");
  Check(fushi_voice_hook::IsLookupCardCoordinateSpaceResolved(
            fushi_voice_hook::kLookupCoordinateSpaceClientPhysicalPixels) &&
            fushi_voice_hook::IsLookupCardCoordinateSpaceResolved(
            fushi_voice_hook::kLookupCoordinateSpacePrimaryLayer) &&
            !fushi_voice_hook::IsLookupCardCoordinateSpaceResolved(
                fushi_voice_hook::kLookupCoordinateSpaceDesignSurface) &&
            !fushi_voice_hook::IsLookupCardCoordinateSpaceResolved(
                fushi_voice_hook::kLookupCoordinateSpaceLayoutLocal),
        "client/primaryLayer 有完整 transform；design/layout-local 必须拒绝");
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
  TestCaptureSuppressHasExactControlIdentity();
  TestAcceptedFramesAlwaysFitInsideTheirBitmapSlot();
  TestV14LookupRegionIsPureAppendOverV13();
  TestV16V17AndV19OnlyAppendOverV15();
  TestV21GeometryAdmissionPublication();
  TestV19ShieldPublicationAndVerifiedGate();
  TestV19AttachedGeometryOwnershipSnapshot();
  TestV19AdmissionIsPureAppendOverV17();
  TestAdmissionRoundTrip();
  TestSha256HexFormatting();
  TestHeaderMirrorsCompileTimeConstants();
  if (g_failures != 0) {
    fprintf(stderr, "lookup ipc contract test failures: %d\n", g_failures);
    return 1;
  }
  printf("lookup ipc contract test ok\n");
  return 0;
}
