// 紧凑 x86（32 位）指令长度解码 + 「函数体内首个被接受的 call 目标」。纯函数，hook/测试共用。
//
// 用途：从 KiriKiri 的 TVPCreateIStream 函数体里逐指令步进，找出它调用的内部 TVPCreateStream。
// 逐指令步进（而不是裸扫 E8 字节）是为了不把立即数 / 位移里的杂散 E8 误认成 call。
// 覆盖 MSVC 与 BCB（C++Builder）SEH 序言的指令集；未知操作码返回 0，调用方据此放弃定位，
// 宁可不 hook 也不误 hook。替代 KrkrExtract 的完整 LDE GetOpCodeSize32。
//
// 操作数宽度前缀 0x66 必须记下来：它把 imm32 变成 imm16。BCB 的 try 帧序言用
// `mov word ptr [ebp-20h], 0`（66 C7 45 E0 00 00）记录异常状态，按 imm32 算会多走 2 字节、
// 后续全部错位（BUG-2887，Fate/stay night[Realta Nua] 真机）。
#pragma once

#include <cstdint>

namespace fushi_voice_hook {
namespace x86 {

// E8/E9 rel32 的目标 = 指令地址 + 5 + rel32。
inline uint8_t* RelCallDest(const uint8_t* p) {
  int32_t rel = 0;
  for (int k = 3; k >= 0; --k) rel = static_cast<int32_t>((static_cast<uint32_t>(rel) << 8) | p[1 + k]);
  return const_cast<uint8_t*>(p) + 5 + rel;
}

inline uint32_t InsnLen32(const uint8_t* p) {
  uint32_t i = 0;
  bool opsize16 = false;
  for (;;) {  // 前缀（段/操作数/地址/rep/lock）逐个吃掉，操作数宽度另记。
    const uint8_t b = p[i];
    if (b == 0x66) {
      opsize16 = true;
      i++;
      continue;
    }
    if (b == 0x67 || b == 0xF0 || b == 0xF2 || b == 0xF3 || b == 0x2E || b == 0x36 ||
        b == 0x3E || b == 0x26 || b == 0x64 || b == 0x65) {
      i++;
      continue;
    }
    break;
  }
  const uint32_t immz = opsize16 ? 2u : 4u;  // Intel 记作 Iz：随操作数宽度变
  const uint8_t op = p[i++];
  auto modrm_len = [&]() -> uint32_t {
    const uint8_t m = p[i];
    const uint8_t mod = static_cast<uint8_t>(m >> 6);
    const uint8_t rm = static_cast<uint8_t>(m & 7);
    uint32_t len = 1;  // modrm 本身
    if (mod != 3) {
      if (rm == 4) {  // SIB
        const uint8_t sib = p[i + 1];
        len += 1;
        if (mod == 0 && (sib & 7) == 5) len += 4;  // disp32
      } else if (mod == 0 && rm == 5) {
        len += 4;  // disp32
      }
      if (mod == 1) {
        len += 1;  // disp8
      } else if (mod == 2) {
        len += 4;  // disp32
      }
    }
    return len;
  };
  switch (op) {
    case 0x90: case 0xC3: case 0xC9: case 0xCC: case 0xF4:
      return i;
    case 0xC2:
      return i + 2;  // ret imm16
    case 0x40: case 0x41: case 0x42: case 0x43: case 0x44: case 0x45: case 0x46: case 0x47:
    case 0x48: case 0x49: case 0x4A: case 0x4B: case 0x4C: case 0x4D: case 0x4E: case 0x4F:
    case 0x50: case 0x51: case 0x52: case 0x53: case 0x54: case 0x55: case 0x56: case 0x57:
    case 0x58: case 0x59: case 0x5A: case 0x5B: case 0x5C: case 0x5D: case 0x5E: case 0x5F:
    case 0x91: case 0x92: case 0x93: case 0x94: case 0x95: case 0x96: case 0x97:
      return i;  // push/pop/inc/dec/xchg-eax reg
    case 0x6A:
      return i + 1;  // push imm8
    case 0x68:
      return i + immz;  // push imm16/32
    case 0xEB:
      return i + 1;  // jmp rel8
    case 0xE8: case 0xE9:
      return i + 4;  // call/jmp rel32（32 位代码里不受 0x66 影响，见上方 opsize 只作用于立即数）
    case 0xA0: case 0xA1: case 0xA2: case 0xA3:
      return i + 4;  // mov al/eax,[moffs32] 及反向（偏移宽度跟地址宽度，不跟操作数宽度）
    case 0xA8:
      return i + 1;  // test al,imm8
    case 0xA9:
      return i + immz;  // test eax/ax,imm
    case 0xB0: case 0xB1: case 0xB2: case 0xB3: case 0xB4: case 0xB5: case 0xB6: case 0xB7:
      return i + 1;  // mov r8,imm8
    case 0xB8: case 0xB9: case 0xBA: case 0xBB: case 0xBC: case 0xBD: case 0xBE: case 0xBF:
      return i + immz;  // mov r16/32,imm
    case 0x04: case 0x0C: case 0x14: case 0x1C: case 0x24: case 0x2C: case 0x34: case 0x3C:
      return i + 1;  // arith al,imm8
    case 0x05: case 0x0D: case 0x15: case 0x1D: case 0x25: case 0x2D: case 0x35: case 0x3D:
      return i + immz;  // arith eax/ax,imm
    case 0x70: case 0x71: case 0x72: case 0x73: case 0x74: case 0x75: case 0x76: case 0x77:
    case 0x78: case 0x79: case 0x7A: case 0x7B: case 0x7C: case 0x7D: case 0x7E: case 0x7F:
      return i + 1;  // jcc rel8
    case 0x80: case 0x83: case 0xC0: case 0xC1: case 0xC6: case 0x6B:
      return i + modrm_len() + 1;  // modrm + imm8
    case 0x81: case 0xC7: case 0x69:
      return i + modrm_len() + immz;  // modrm + imm16/32
    case 0x00: case 0x01: case 0x02: case 0x03:
    case 0x08: case 0x09: case 0x0A: case 0x0B:
    case 0x10: case 0x11: case 0x12: case 0x13:
    case 0x18: case 0x19: case 0x1A: case 0x1B:
    case 0x20: case 0x21: case 0x22: case 0x23:
    case 0x28: case 0x29: case 0x2A: case 0x2B:
    case 0x30: case 0x31: case 0x32: case 0x33:
    case 0x38: case 0x39: case 0x3A: case 0x3B:
    case 0x84: case 0x85: case 0x86: case 0x87:
    case 0x88: case 0x89: case 0x8A: case 0x8B:
    case 0x8D: case 0x8F:
    case 0xD0: case 0xD1: case 0xD2: case 0xD3:
    case 0xFE: case 0xFF: case 0x62: case 0x63:
      return i + modrm_len();  // 纯 modrm
    case 0x0F: {
      const uint8_t op2 = p[i++];
      if (op2 >= 0x80 && op2 <= 0x8F) return i + 4;  // jcc rel32
      return i + modrm_len();                        // setcc/movzx/movsx/imul 等（best effort）
    }
    default:
      return 0;  // 未知 → 放弃定位
  }
}

// 从 fn 起逐指令步进（最多 window 字节），返回第一个被 accept 接受的 `call rel32` 目标；
// 碰到 ret / int3 / 未知指令就停，返回 nullptr。accept 签名：bool(uint8_t* dest)。
template <class Accept>
uint8_t* FindFirstAcceptedCallTarget(const uint8_t* fn, uint32_t window, Accept accept) {
  uint32_t off = 0;
  while (off < window) {
    const uint8_t* p = fn + off;
    if (p[0] == 0xC3 || p[0] == 0xCC) break;
    if (p[0] == 0xE8) {
      uint8_t* dest = RelCallDest(p);
      if (accept(dest)) return dest;
    }
    const uint32_t len = InsnLen32(p);
    if (len == 0) break;
    off += len;
  }
  return nullptr;
}

}  // namespace x86
}  // namespace fushi_voice_hook
