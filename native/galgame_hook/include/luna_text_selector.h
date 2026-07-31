#ifndef HIBIKI_LUNA_TEXT_SELECTOR_H_
#define HIBIKI_LUNA_TEXT_SELECTOR_H_

#include <cstddef>
#include <cstring>
#include <cstdint>
#include <cwchar>
#include <map>
#include <string>
#include <vector>

namespace hibiki_voice_hook {

// 一个完整句的最小字符数。低于它不做前缀折叠，避免把「ああ」这类叠字噪声
// （交给 LunaTextIsArtifact 判）或短感叹句误截。
constexpr int kLunaMinFoldedLineChars = 4;

// Some KiriKiri/Luna hook paths concatenate an already complete line with an
// exact second copy.  Preserve a view of the first complete line instead of
// discarding the event as an artifact.  A one-character doubled string remains
// untouched so the artifact filter can continue rejecting single-character
// repetition noise.
//
// BUG-1175：旧实现只认「整串恰好二倍」（前半 == 后半）。带 ruby 的台词会被
// KiriKiriZ 分别以 base（汉字）和 ruby（假名）两种形式送进同一个 hook 点，再叠上
// 本 hook 面固有的完整行双写，实际收到的是 `A A B B A A`（A=汉字版、B=注音版）——
// 前半 `AAB` != 后半 `BAA`，整串判据一条都不命中，整串原样入环，于是浮窗/台词列表/
// 制卡内容里一句话出现六遍。
//
// 判据是**块级**的：整串必须能被无剩余地切成一串「连续成对重复」的块
// `s1 s1 s2 s2 … sn sn`（每块 >= kLunaMinFoldedLineChars 字），命中才返回 |s1|。
// `A A B B A A` 正是这个形状 → 折成 A；「整串恰好二倍」是 n == 1 的特例，
// 旧行为被完整覆盖。
//
// 判据**不得**放宽成「开头二倍就截掉后面全部」：那会把 galgame 里极常见的
// 合法叠句静默腰斩，而且残句短到过不了 LunaTextIsArtifact，会被当干净行写进环：
//   「わかったわかった、もう行くよ」→「わかった」
//   「ありがとうありがとう、本当に助かった」→「ありがとう」
// 块级判据下这两句的尾巴（`、もう行くよ` / `、本当に助かった`）拆不成成对重复块，
// 整串判定失败 → 原样放行。**宁可漏折，也不能吞用户的字。**
//
// 长度上界只是防御性护栏；超界同样走「原样放行」这个安全方向。
constexpr int kLunaMaxFoldScanChars = 4096;

inline int LunaNormalizedTextLength(const wchar_t* text, int len) {
  if (text == nullptr || len < kLunaMinFoldedLineChars * 2) return len;
  if (len > kLunaMaxFoldScanChars) return len;
  // block[i] > 0：text[i, len) 可完整拆成成对重复块，值是其首块长度；
  // block[len] = -1 是「尾巴为空、已拆完」的哨兵；0 表示拆不动。
  std::vector<int> block(static_cast<size_t>(len) + 1, 0);
  block[static_cast<size_t>(len)] = -1;
  for (int i = len - kLunaMinFoldedLineChars * 2; i >= 0; --i) {
    for (int k = kLunaMinFoldedLineChars; i + 2 * k <= len; ++k) {
      // 先看尾巴能否拆完再比字符：绝大多数位置在这一步就被剪掉。
      if (block[static_cast<size_t>(i + 2 * k)] == 0) continue;
      bool doubled = true;
      for (int j = 0; j < k && doubled; ++j) {
        if (text[i + j] != text[i + k + j]) doubled = false;
      }
      if (doubled) {
        block[static_cast<size_t>(i)] = k;
        break;
      }
    }
  }
  return block[0] > 0 ? block[0] : len;
}

inline int LunaNormalizedTextLengthForHook(const char* hook_name,
                                           const wchar_t* text, int len) {
  if (hook_name == nullptr || std::strcmp(hook_name, "EmbedKrkrZ") != 0) {
    return len;
  }
  return LunaNormalizedTextLength(text, len);
}

inline bool LunaTextIsArtifact(const wchar_t* text, int len) {
  if (text == nullptr || len <= 1) return false;
  if ((len % 2) == 0) {
    const int half = len / 2;
    if (std::wstring(text, text + half) == std::wstring(text + half, text + len)) {
      return true;
    }
  }
  int segments = 0;
  int first_run = 0;
  bool uniform = true;
  for (int i = 0; i < len;) {
    int j = i + 1;
    while (j < len && text[j] == text[i]) ++j;
    const int run = j - i;
    if (segments == 0) first_run = run;
    else if (run != first_run) uniform = false;
    ++segments;
    i = j;
  }
  if (segments >= 3 && uniform && first_run >= 2) return true;
  int adjacent_equal = 0;
  for (int i = 1; i < len; ++i) {
    if (text[i] == text[i - 1]) ++adjacent_equal;
  }
  return len > 4 && adjacent_equal * 100 >= (len - 1) * 30;
}

// ── hook 身份 id：injector 与测试共用同一实现 ────────────────────────
// 放在头里而不是 injector 的 .cpp 里，是为了让跨引擎负向测试能拿真实引擎的
// (addr, hookcode, hookname, ctx, ctx2) 驱动**生产实现**，而不是手捏 face 常量自证。
inline uint64_t LunaFnv1a64(uint64_t hash, const void* data, size_t size) {
  const auto* bytes = static_cast<const unsigned char*>(data);
  for (size_t i = 0; i < size; ++i) {
    hash ^= bytes[i];
    hash *= 1099511628211ull;
  }
  return hash;
}

inline uint64_t LunaHashHookNames(uint64_t hash, const wchar_t* hookcode,
                                  const char* hookname) {
  if (hookcode != nullptr) {
    hash = LunaFnv1a64(hash, hookcode, std::wcslen(hookcode) * sizeof(wchar_t));
  }
  if (hookname != nullptr) {
    hash = LunaFnv1a64(hash, hookname, std::strlen(hookname));
  }
  return hash == 0 ? 1 : hash;
}

// 展示/诊断用的全维度线程 id：含 ctx（调用点上下文/返回地址）与 ctx2。
inline uint64_t LunaTextThreadIdFrom(uint32_t process_id, uint64_t addr,
                                     uint64_t ctx, uint64_t ctx2,
                                     const wchar_t* hookcode,
                                     const char* hookname) {
  // 字段喂入顺序与旧的 injector 实现逐字节一致，保证 thread_id 取值不变。
  uint64_t hash = 1469598103934665603ull;
  hash = LunaFnv1a64(hash, &process_id, sizeof(process_id));
  hash = LunaFnv1a64(hash, &addr, sizeof(addr));
  hash = LunaFnv1a64(hash, &ctx, sizeof(ctx));
  hash = LunaFnv1a64(hash, &ctx2, sizeof(ctx2));
  return LunaHashHookNames(hash, hookcode, hookname);
}

// hook「面」id：与 LunaTextThreadIdFrom 同源，**只去掉 ctx**（BUG-1159）。
//
// 为什么只去 ctx：LunaHook 的 `ThreadParam` 里两个上下文字段语义完全不同——
// * `ctx`  = 调用点（返回地址）。同一个 hook 面在不同剧情分支下会走不同调用点，
//   它一变 thread_id 就变，旧的精确匹配把整段台词丢掉——这正是 BUG-1159。
// * `ctx2` = split H 码的 **split 值**，是引擎适配方显式声明的语义分类
//   （典型就是「角色名 vs 正文 vs 选项」）。它必须留在 face 里，否则 split H 码
//   引擎的角色名会被当成「同一 hook 面的兄弟线程」混进正文流。
// 包含 ctx2 是保守方向：最差也只是对该维度保持旧的精确匹配行为，不会混流。
inline uint64_t LunaTextFaceIdFrom(uint32_t process_id, uint64_t addr,
                                   uint64_t ctx2, const wchar_t* hookcode,
                                   const char* hookname) {
  uint64_t hash = 1469598103934665603ull;
  hash = LunaFnv1a64(hash, &process_id, sizeof(process_id));
  hash = LunaFnv1a64(hash, &addr, sizeof(addr));
  hash = LunaFnv1a64(hash, &ctx2, sizeof(ctx2));
  return LunaHashHookNames(hash, hookcode, hookname);
}

// 手动/记忆选定的线程是否应放行本行（纯函数，便于单测）。
//
// BUG-1159：`selected_text_thread_id` 存的是一个具体的 `TextSlot::thread_id`，而
// thread_id = FNV1a(processId, addr, **ctx**, ctx2, hookcode, hookname) —— 含调用点。
// 同一个 hook 面（同 addr + 同 ctx2 + 同 hookcode/hookname）在不同调用路径下 ctx 会变，
// thread_id 随之变，旧的 `manually_selected == thread_id` 精确匹配就把整段台词丢掉：
// 真机实测中 textseq83 之后连续 16 句语音资源（间隔规整 5~8s）全部没有对应文本，
// 文本环没有候选 → 资源配对 kExpired → 写成无标记文件 → 消费端只剩 200ms 时间窗
// 兜底 → 兜不住 → 整段降级成 system_loopback。
//
// ctx 参与 thread_id 是**有意的**（诊断/区分同 hook 的并行调用点），所以这里不改
// thread_id 的算法，只把**过滤粒度**放宽到 hook 面：选定线程的 face 与本行 face 相同
// 即放行。face 未知（还没见过选定线程的行）时退回精确匹配，语义与旧实现一致。
//
// 放宽的只有 ctx 这一维；split H 码的 ctx2（角色名/正文分类）仍在 face 里，见
// [LunaTextFaceIdFrom]。
inline bool LunaSelectedThreadAccepts(uint64_t manually_selected,
                                      uint64_t thread_id,
                                      uint64_t selected_face,
                                      uint64_t face_id) {
  if (manually_selected == thread_id) return true;
  return selected_face != 0 && selected_face == face_id;
}

// 文本环（Ring A）的准入判定。
//
// BUG-1193 / v12：这里**不再有"自动选干净线程"**。旧实现按 hookcode 统计 clean/dirty，
// 累计够 3 行干净就锁定赢家，此后只发布赢家的行。它撑住了很长一段时间，但有两个无法
// 在本层解决的问题：
//   ① 猜错就没有出路。赢家一旦锁定，其余线程在采集端就被丢弃，用户在 UI 里看到的是
//     一堆没有内容的空壳线程，"选不动"——这正是用户报的症状；
//   ② 它把"哪条是台词"这个只有用户能回答的问题，交给了一个字符级启发式。带汉化补丁的
//     KiriKiri 上这个启发式必然失败：原文和译文经由**同一个 hook**（EmbedKrkrZ 带
//     NO_CONTEXT，ctx 被强制清零）流出，两种语言的 ThreadParam 逐字节相同，任何统计
//     都不可能把它们分开。
// v12 的答案是不猜：没有显式选择就不发布，由 UI 引导用户从**线程预览区**（见
// voice_hook_ipc.h ThreadPreviewSlot）挑一条。预览区按线程分槽，不受本判定影响，所以
// "让用户看见所有线程"和"文本环只装选定线程"不再互相排斥——这是删掉赢家逻辑的前提。
//
// 唯一准入来源是用户选定的 selected_text_thread_id。profile 的 `prefer=` 只保留为旧配置
// 元数据，v12 不得据此绕过显式选择。
class LunaTextSelector {
 public:
  // 判定本行是否写入文本环。[face_id] 是不含 ctx 的 hook 面 id（见
  // LunaSelectedThreadAccepts）；传 0 表示调用方无法提供，此时退化为精确 thread_id 匹配。
  //
  // [manually_selected] 为 0 表示用户尚未为本游戏选定线程：**返回 false**，一行都不发布。
  // 这是有意的——见类注释。伪影行任何情况下都不进文本环（预览区另有 artifact 标记位，
  // 脏线程在 UI 里仍然看得见，不会被藏掉）。
  bool AcceptsLine(uint64_t thread_id, bool artifact, uint64_t manually_selected,
                   uint64_t face_id = 0) {
    NoteFace(thread_id, face_id);
    if (artifact) return false;
    if (manually_selected == 0) return false;
    return LunaSelectedThreadAccepts(manually_selected, thread_id,
                                     FaceOf(manually_selected), face_id);
  }

  // 登记一条 thread_id → face 映射。
  //
  // BUG-1159：这一步必须对**每一行**做，且必须早于准入判定。未选择阶段的行只进入
  // 预览区、不进入文本环；跨会话记忆恢复（Dart `_maybeRestoreTextThread`）会从
  // 「本会话已出过 >= 3 行」的线程里挑一条写进 `selected_text_thread_id`，所以这些
  // 预览行也必须提前登记 face。
  // 登记在全路径完成后，「选定线程已出过 >= 3 行」就硬性蕴含「face 已知」。
  void NoteFace(uint64_t thread_id, uint64_t face_id) {
    if (face_id != 0 && thread_id != 0) thread_face_[thread_id] = face_id;
  }

  // 已登记的 thread_id → hook 面 id；未见过返回 0。
  uint64_t FaceOf(uint64_t thread_id) const {
    const auto it = thread_face_.find(thread_id);
    return it == thread_face_.end() ? 0 : it->second;
  }

  void Reset() { thread_face_.clear(); }

 private:
  // thread_id → hook 面 id。只增不删：一次会话内 hook 面数量有界（每个 hook 的每个
  // 调用上下文一条），且必须跨「用户选定线程」之前/之后都能查到。
  std::map<uint64_t, uint64_t> thread_face_;
};

}  // namespace hibiki_voice_hook

#endif  // HIBIKI_LUNA_TEXT_SELECTOR_H_
