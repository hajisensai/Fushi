#pragma once

#include <cstddef>
#include <cstdint>

#include "../include/voice_hook_ipc.h"

namespace fushi_voice_hook {

// 宿主 exe 的 SHA-256（小写十六进制；空串 = 本会话还没人算过）。
//
// 为什么是一个共享槽，而不是各 adapter 各留一份：
//
// 这是**一个进程一个值**的事实——Leaf 和 Siglus 的 profile 解析都对
// `GetModuleFileNameW(nullptr)` 做 SHA-256，算的是同一个字节序列，却各自存进了自己的
// 静态缓冲。而真正需要这个摘要的地方，是准入收敛到「不支持或未识别」的那一刻：
// 那一刻的定义就是**没有任何 adapter 认领**，于是各家私有缓冲在那里全部够不着，
// 而这条路径的注释承诺给用户的「用不了 + 请把 exe 摘要报上来」发布出去是个空串——
// 没有摘要，用户报上来的就只有"用不了"，我们这边一点可查的东西都没有。
//
// 谁先算出来谁存进来（profile 解析本来就要算，不额外读盘），读者只有汇总那一处。
// 一次性写入：同一个 exe 的摘要不会变，先到的那份就是答案，后来者直接返回——因此
// 多个 profile 解析线程同时写也无所谓，写的是同一串字符。
inline char* HostExecutableSha256Storage() {
  static char storage[kHookModuleDigestChars] = {};
  return storage;
}

// profile 解析算出摘要后调一次。digest 是 32 字节裸摘要（不是十六进制）。
inline void PublishHostExecutableSha256(const uint8_t* digest,
                                        size_t digest_bytes) {
  char* slot = HostExecutableSha256Storage();
  if (slot[0] != '\0') return;
  FormatSha256Hex(digest, digest_bytes, slot, kHookModuleDigestChars);
}

// 空串表示"本会话没算出来"。调用方必须原样发布空串，不要拿一串零冒充摘要——
// host 侧要能说"算不出"，而不是显示 64 个 0 让用户以为那就是他的 hash。
inline const char* HostExecutableSha256Hex() {
  return HostExecutableSha256Storage();
}

}  // namespace fushi_voice_hook
