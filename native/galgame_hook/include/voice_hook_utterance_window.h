#ifndef FUSHI_VOICE_HOOK_UTTERANCE_WINDOW_H_
#define FUSHI_VOICE_HOOK_UTTERANCE_WINDOW_H_

#include <cstddef>
#include <cstdint>

// 整句语音拼接窗口的**下界**推算（BUG-1593）。
//
// 为什么需要它：`VoiceClip::timestamp_ms` 是 hook 在 XAudio2/DirectSound 回调里打的**提交**
// 时刻，不是这段 PCM 被听到的时刻。流式引擎必然按缓冲深度提前提交，两者相差「提交时该源还
// 没播完的积压」。KiriKiri 每句语音新建一个 DirectSound secondary buffer，Play 之前把整个
// 缓冲一次性灌满——实测フタマタ恋愛：96000B 静音底（1000ms）+ 4×12000B 人声（500ms）共
// 1500ms 音频**落在同一个 tick**，而这一整块的提交时刻比文本 hook 早 **219ms**。窗口下界
// 若是写死的 `ts-200ms`，这一整块必然整体出界，于是**每一句**都被削掉开头（BUG-1593）。
//
// 判据为什么不能逐对比较相邻 clip 的间隔：`GetTickCount64` 只有 ~15ms 粒度，同一游戏相邻
// 两句量到的「突发块到流式段」的间隔一边 62ms 一边 63ms，任何逐对阈值都会在这点噪声上
// 二选一地翻车（本修复第一版实测就是这么漏掉一半句子的）。
//
// 改用**聚合**判据：区间 `[j, i0)` 承载的音频时长若显著快于它被写入的墙钟跨度
// （`audio > 1.25 * wall`），说明引擎正在提前灌入，这段属于本句开头。实时写入的混音 / BGM
// 源 `audio ≈ wall`（实测偏差 <10%），判据不成立，下界原样退回 `text_ts - back_ms` ——
// 对这类源的取音**逐字节等价于旧行为**（真机实测差异 0 字节）。1.25 这个倍率把「提前灌入」
// （实测超出 20 倍以上）和「实时写入」（实测 <1.1 倍）分得很开，不在噪声量级上。
namespace fushi_voice_hook {

// 文本时刻之前仍算作本句的固定回看量（旧行为的唯一常量，保持不变）。
constexpr int64_t kUtteranceBackMs = 200;
// 下界最多回看多远：与前向窗口同量级，兜住「选到长流式源」时的失控回溯。
constexpr int64_t kUtteranceMaxBackMs = 6000;

struct UtteranceClipTiming {
  int64_t timestamp_ms;  // 提交时刻（VoiceClip::timestamp_ms）
  int64_t duration_ms;   // 该段承载的音频时长
};

// [clips, clips+count) 必须是**选定语音源**的段、按提交顺序（seq 升序）。
// 返回值是提交时间轴上的下界：调用方保留 `timestamp_ms >= 返回值` 的段。
// 恒有 `返回值 <= text_ts_ms - back_ms`，即只可能比旧行为多收、不可能少收。
inline int64_t UtteranceLowerBoundMs(const UtteranceClipTiming* clips,
                                     size_t count, int64_t text_ts_ms,
                                     int64_t back_ms = kUtteranceBackMs,
                                     int64_t max_back_ms = kUtteranceMaxBackMs) {
  const int64_t base = text_ts_ms - back_ms;
  if (clips == nullptr || count == 0) {
    return base;
  }
  size_t i0 = count;
  for (size_t k = 0; k < count; ++k) {
    if (clips[k].timestamp_ms >= base) {
      i0 = k;
      break;
    }
  }
  // i0 == 0：最早的段已经在窗口里，没有开头可捡。
  // i0 == count：边界之后一段都没有，本来就取不到这句，扩下界没有意义。
  if (i0 == 0 || i0 == count) {
    return base;
  }
  int64_t lower = base;
  int64_t audio = 0;
  for (size_t j = i0; j-- > 0;) {
    audio += clips[j].duration_ms;
    if (text_ts_ms - clips[j].timestamp_ms > max_back_ms) {
      break;
    }
    const int64_t wall =
        clips[i0].timestamp_ms - clips[j].timestamp_ms;
    if (audio * 4 > wall * 5) {
      lower = clips[j].timestamp_ms;  // 取满足条件的**最早**那个 j
    }
  }
  return lower < base ? lower : base;
}

}  // namespace fushi_voice_hook

#endif  // FUSHI_VOICE_HOOK_UTTERANCE_WINDOW_H_
