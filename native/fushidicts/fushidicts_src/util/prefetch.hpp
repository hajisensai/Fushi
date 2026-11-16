#pragma once

// 预取一条缓存行（只读、马上要用）。纯提示：地址无效也不会出错，没有对应指令的
// 平台上是空操作。
#if defined(__GNUC__) || defined(__clang__)
#define FUSHI_PREFETCH(addr) __builtin_prefetch((addr), 0, 3)
#elif defined(_MSC_VER) && (defined(_M_X64) || defined(_M_IX86))
#include <xmmintrin.h>
#define FUSHI_PREFETCH(addr) _mm_prefetch(reinterpret_cast<const char*>(addr), _MM_HINT_T0)
#elif defined(_MSC_VER) && defined(_M_ARM64)
#include <intrin.h>
#define FUSHI_PREFETCH(addr) __prefetch(addr)
#else
#define FUSHI_PREFETCH(addr) ((void)(addr))
#endif
