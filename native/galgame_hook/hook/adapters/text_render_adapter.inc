// P1 zero-behaviour-change split: included inside dll_main.cpp anonymous namespace.
// == wen ben hook (grab dialogue text) ==
// 覆盖 GDI 文本渲染 API（galgame 经典 hook 面）：GetGlyphOutlineW 逐字形渲染逐字累积成行，
// ExtTextOutW/TextOutW/DrawTextW 整串直接成行；写进共享内存文本环供 host 消费。
//
// 诚实局限：只覆盖 **GDI 渲染文本**的游戏。KiriKiriZ / RenPy / Unity 走 FreeType / DirectWrite
// / 自绘位图字体，GDI 文本 API 抓不到——那些靠 LunaTranslator 等备选覆盖，不在本组件范围。也
// 不写引擎特定 H-code（逐游戏内存 callsite/参数偏移的 DB，是 LunaHook 的活儿，超出本组件）。
//
// 并发模型：文本 hook **不是**音频回调，允许加锁 + 静态缓冲（仅音频回调是零阻塞红线）；但仍
// 不做重 IO。所有累积/去重/写环都在 g_text_cs 保护下、并以 g_capture_enabled 兜住 DETACH
// 解映射窗口（与音频回调同一总开关）。

// 文本渲染 API 原型（GetProcAddress 动态取址，不链接 gdi32/user32.lib）。
typedef DWORD(WINAPI* GetGlyphOutlineW_t)(HDC, UINT, UINT, LPGLYPHMETRICS, DWORD,
                                          LPVOID, const MAT2*);
typedef BOOL(WINAPI* ExtTextOutW_t)(HDC, int, int, UINT, const RECT*, LPCWSTR,
                                    UINT, const INT*);
typedef BOOL(WINAPI* TextOutW_t)(HDC, int, int, LPCWSTR, int);
typedef int(WINAPI* DrawTextW_t)(HDC, LPCWSTR, int, LPRECT, UINT);

GetGlyphOutlineW_t g_orig_GetGlyphOutlineW = nullptr;
ExtTextOutW_t g_orig_ExtTextOutW = nullptr;
TextOutW_t g_orig_TextOutW = nullptr;
DrawTextW_t g_orig_DrawTextW = nullptr;

// 文本累积/去重的锁与缓冲（与音频回调隔离，允许加锁；锁在全局捕获状态区声明）。
constexpr int kMaxLineChars = 500;           // 一行台词上界（UTF-16 字符数）
wchar_t g_glyph_buf[kMaxLineChars + 8];      // GetGlyphOutlineW 逐字累积缓冲
int g_glyph_len = 0;                         // 当前累积字符数
ULONGLONG g_glyph_last_tick = 0;             // 上次 GetGlyphOutlineW 时刻（判行界）
wchar_t g_last_flushed[kMaxLineChars + 8];   // 上一条已 flush 的行（去重）
int g_last_flushed_len = 0;

// 把一行文本写进共享内存文本环（调用者持 g_text_cs，仅序列化本 DLL 内部去重状态）。
// 文本环是**多写者**：本 DLL（游戏内 GDI hook）和 host 侧 injector 里的 LunaHook 写同一个环，
// 跨进程并发。故 slot 号必须用 InterlockedIncrement64 原子 fetch-add 预留——绝不与另一写者撞
// 同一槽，也绝不丢更新（旧的“读 text_write_count → 填 → plain store idx+1”是非原子 RMW，与
// 原子写者交错时会互相覆盖计数、丢行或读到半写槽）。写序：原子占号 → 填文本字节 + 字段 →
// **最后**写 seq=占到的号作完成标记（reader 校验 slot.seq==text_write_count 才取该槽；x86/x64
// store 有序 TSO，前面的数据写对 reader 先于 seq 可见）。首次 flush 置 text_hooked=1。
void WriteTextRingEntryLocked(const wchar_t* text, int char_len,
                              uint64_t thread_id, uint64_t thread_address,
                              uint64_t thread_context, uint32_t source_kind,
                              const char* hook_name,
                              const wchar_t* hook_code) {
  if (g_text_base == nullptr || g_header == nullptr || char_len <= 0) {
    return;
  }
  // LunaHook（引擎精确、干净）一旦活跃，GDI 文本 hook 让位，不再写文本环——否则游戏为粗体/描边
  // 每字重画会让 GetGlyphOutlineW 累加出「ここのの」式伪影，与 LunaHook 干净行混在一起污染卡片。
  // GDI 仅在 LunaHook 覆盖不到的引擎（luna_active==0）时作兜底文本源。音频 hook 不看此标志。
  if (source_kind == hibiki_voice_hook::kTextSourceGdi &&
      g_header->luna_active != 0) {
    return;
  }
  // 原子预留唯一槽位：返回自增后的新值（=占到的 1 基序号，0 基 idx=reserved-1）。
  const LONGLONG reserved = InterlockedIncrement64(
      reinterpret_cast<volatile LONGLONG*>(&g_header->text_write_count));
  const uint64_t idx = static_cast<uint64_t>(reserved) - 1;
  const size_t slot_off =
      static_cast<size_t>(idx % kTextSlotCount) * kTextSlotBytes;
  uint8_t* slot = g_text_base + slot_off;
  auto* ts = reinterpret_cast<TextSlot*>(slot);
  memset(ts, 0, sizeof(TextSlot));
  uint32_t max_bytes = kTextSlotBytes - static_cast<uint32_t>(sizeof(TextSlot));
  max_bytes -= (max_bytes % static_cast<uint32_t>(sizeof(wchar_t)));  // wchar 边界
  uint32_t byte_len = static_cast<uint32_t>(char_len) *
                      static_cast<uint32_t>(sizeof(wchar_t));
  if (byte_len > max_bytes) {
    byte_len = max_bytes;  // 截断到槽容量（kTextSlotBytes-头长，wchar 对齐）
  }
  memcpy(slot + sizeof(TextSlot), text, byte_len);
  ts->timestamp_ms = GetTickCount64();
  ts->byte_len = byte_len;
  ts->is_utf8 = 0;                            // UTF-16LE
  ts->thread_id = thread_id;
  ts->thread_address = thread_address;
  ts->thread_context = thread_context;
  ts->process_id = GetCurrentProcessId();
  ts->source_kind = source_kind;
  if (hook_name != nullptr) {
    const size_t name_len = strnlen_s(hook_name, kTextHookNameChars - 1);
    ts->hook_name_len = static_cast<uint32_t>(name_len);
    memcpy(ts->hook_name, hook_name, name_len);
  }
  if (hook_code != nullptr) {
    const size_t code_len = wcsnlen_s(hook_code, kTextHookCodeChars - 1);
    ts->hook_code_len = static_cast<uint32_t>(code_len);
    memcpy(ts->hook_code, hook_code, code_len * sizeof(wchar_t));
  }
  ts->seq = static_cast<uint64_t>(reserved);  // 完成标记，**最后**写
  if (g_header->text_hooked == 0) {
    g_header->text_hooked = 1;            // 首次 flush：文本 hook proof-of-life
  }
}

void WriteTextRingLocked(const wchar_t* text, int char_len) {
  WriteTextRingEntryLocked(text, char_len, 1, 0, 0,
                           hibiki_voice_hook::kTextSourceGdi,
                           "GDI fallback", nullptr);
}

// 过滤 + 去重 + 写环（调用者持 g_text_cs）。过滤：跳空串/纯空白/纯 ASCII 控制；只保留含至少
// 一个非 ASCII（>=0x3000，日文假名/汉字之类）或非空白字符数>=2 的串——避免把 UI 数字/单字母
// 当台词（粗过滤即可，别过度）。去重：与上一条 flush 完全相同则跳过（游戏常重绘同句）。
void FlushLineLocked(const wchar_t* text, int len) {
  if (text == nullptr || len <= 0) {
    return;
  }
  if (len > kMaxLineChars) {
    len = kMaxLineChars;  // 截断到缓冲/环槽上界
  }
  bool has_cjk = false;
  int meaningful = 0;
  for (int i = 0; i < len; i++) {
    const wchar_t c = text[i];
    // 空白/控制字符（空格 0x20、TAB 0x09、CR 0x0D、LF 0x0A、以及 <0x20 控制字符）不计。
    if (c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A || c < 0x20) {
      continue;
    }
    meaningful++;
    if (c >= 0x3000) {
      has_cjk = true;
    }
  }
  if (meaningful == 0) {
    return;  // 空串/纯空白/纯控制
  }
  if (!has_cjk && meaningful < 2) {
    return;  // 单个 ASCII 字符（UI 数字/字母噪声）
  }
  if (len == g_last_flushed_len &&
      memcmp(text, g_last_flushed,
             static_cast<size_t>(len) * sizeof(wchar_t)) == 0) {
    return;  // 与上一条完全相同（重绘同句）
  }
  memcpy(g_last_flushed, text, static_cast<size_t>(len) * sizeof(wchar_t));
  g_last_flushed_len = len;
  WriteTextRingLocked(text, len);
}

// 冲掉 GetGlyphOutlineW 逐字累积缓冲成一行（调用者持 g_text_cs）。
void FlushGlyphAccumLocked() {
  if (g_glyph_len > 0) {
    FlushLineLocked(g_glyph_buf, g_glyph_len);
    g_glyph_len = 0;
  }
}

#if defined(_M_IX86)

// Siglus 3 使用与 32 位 MSVC std::wstring 相同的 24-byte 小字符串布局。当前 Luna 的
// EmbedSiglus2 也从该函数入口的 ECX 读取此对象；在引擎逻辑层拿整句可彻底避开 GDI
// 描边/逐字重画造成的重复字与漏标点。
struct SiglusTextUnionW {
  union {
    const wchar_t* text;
    wchar_t chars[8];
  } storage;
  uint32_t size;
  uint32_t capacity;
};
static_assert(sizeof(SiglusTextUnionW) == 24,
              "Siglus TextUnionW layout changed");

using SiglusExactTextFn = uintptr_t(__thiscall*)(SiglusTextUnionW* self);
SiglusExactTextFn g_orig_SiglusExactText = nullptr;
uintptr_t g_siglus_text_function_rva = 0;

bool IsReadableSpan(const void* pointer, size_t bytes) {
  if (pointer == nullptr || bytes == 0) return false;
  uintptr_t cursor = reinterpret_cast<uintptr_t>(pointer);
  const uintptr_t end = cursor + bytes;
  if (end < cursor) return false;
  while (cursor < end) {
    MEMORY_BASIC_INFORMATION memory = {};
    if (VirtualQuery(reinterpret_cast<const void*>(cursor), &memory,
                     sizeof(memory)) != sizeof(memory) ||
        memory.State != MEM_COMMIT ||
        (memory.Protect & (PAGE_GUARD | PAGE_NOACCESS)) != 0) {
      return false;
    }
    const uintptr_t region_end =
        reinterpret_cast<uintptr_t>(memory.BaseAddress) + memory.RegionSize;
    if (region_end <= cursor) return false;
    cursor = region_end;
  }
  return true;
}

const wchar_t* ReadSiglusText(const SiglusTextUnionW* value,
                              uint32_t* length) {
  if (length == nullptr ||
      !IsReadableSpan(value, sizeof(SiglusTextUnionW)) || value->size == 0 ||
      value->size > 1500 || value->size > value->capacity) {
    return nullptr;
  }
  const wchar_t* text = value->capacity < 8 ? value->storage.chars
                                             : value->storage.text;
  const size_t bytes =
      (static_cast<size_t>(value->size) + 1) * sizeof(wchar_t);
  if (!IsReadableSpan(text, bytes) || text[value->size] != L'\0') {
    return nullptr;
  }
  *length = value->size;
  return text;
}

uintptr_t __fastcall Detour_SiglusExactText(SiglusTextUnionW* self, void*) {
  uint32_t length = 0;
  const wchar_t* text = ReadSiglusText(self, &length);
  if (text != nullptr && g_capture_enabled && g_text_cs_ready) {
    const uintptr_t module =
        reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
    const uintptr_t return_address =
        reinterpret_cast<uintptr_t>(_ReturnAddress());
    const uint64_t callsite_rva =
        return_address >= module ? return_address - module : return_address;
    // Luna 以 hook 地址 + caller context 区分文本线程。沿用同一粒度，名字/正文等不同
    // caller 会出现在下拉框中，用户可像 Luna Translator 一样只选干净台词线程。
    const uint64_t thread_id =
        (static_cast<uint64_t>(g_siglus_text_function_rva) << 32) ^
        callsite_rva;
    wchar_t hook_code[kTextHookCodeChars] = {0};
    _snwprintf_s(hook_code, kTextHookCodeChars, _TRUNCATE,
                 L"EXBWX0@%llX:SiglusEngine.exe",
                 static_cast<unsigned long long>(g_siglus_text_function_rva));

    EnterCriticalSection(&g_text_cs);
    WriteTextRingEntryLocked(
        text, static_cast<int>(length), thread_id,
        g_siglus_text_function_rva, callsite_rva,
        hibiki_voice_hook::kTextSourceSiglus, "SiglusEngine exact", hook_code);
    LeaveCriticalSection(&g_text_cs);
    if (g_header != nullptr) {
      g_header->luna_active = 1;  // 精确引擎文本已实锤，GDI 兜底从此让位。
      g_header->hook_diagnostics |= kDiagSiglusExactTextObserved;
    }
  }
  return g_orig_SiglusExactText(self);
}

bool TryHookSiglusExactText() {
  if (!IsSiglusEngine()) return true;
  if (g_orig_SiglusExactText != nullptr) return true;
  HMODULE module = GetModuleHandleW(nullptr);
  if (module == nullptr) return false;
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(module);
  if (dos->e_magic != IMAGE_DOS_SIGNATURE) return false;
  const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS*>(
      reinterpret_cast<const uint8_t*>(module) + dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE) return false;

  const IMAGE_SECTION_HEADER* section = IMAGE_FIRST_SECTION(nt);
  for (uint16_t i = 0; i < nt->FileHeader.NumberOfSections; ++i) {
    if ((section[i].Characteristics & IMAGE_SCN_MEM_EXECUTE) == 0) continue;
    const size_t section_bytes = section[i].Misc.VirtualSize;
    const auto* section_base = reinterpret_cast<const uint8_t*>(module) +
                               section[i].VirtualAddress;
    if (!IsReadableSpan(section_base, section_bytes)) continue;
    const size_t offset = hibiki_voice_hook::siglus::FindExactTextFunctionOffset(
        section_base, section_bytes);
    if (offset == hibiki_voice_hook::siglus::kInvalidTextFunctionOffset) {
      continue;
    }
    void* target = const_cast<uint8_t*>(section_base + offset);
    g_siglus_text_function_rva =
        static_cast<uintptr_t>(section[i].VirtualAddress) + offset;
    if (!HookFn(target, reinterpret_cast<void*>(&Detour_SiglusExactText),
                reinterpret_cast<void**>(&g_orig_SiglusExactText))) {
      g_siglus_text_function_rva = 0;
      return false;
    }
    if (g_header != nullptr) {
      g_header->text_hooked = 1;
      g_header->hook_diagnostics |= kDiagSiglusExactTextHookReady;
    }
    return true;
  }
  return false;
}

#else

bool TryHookSiglusExactText() { return true; }

#endif  // _M_IX86

// -- detour: GetGlyphOutlineW（gdi32，galgame 最经典逐字形文本 hook）--
// 多数 GDI VN 逐字渲染字形经此。uChar 是当前渲染字符：逐字累积成行，用**时间空隙**判行界
// （距上次 >120ms 视为新行——先 flush 已累积再重开累积），缓冲将满时强制 flush。
// GGO_GLYPH_INDEX 时 uChar 是字形索引而非字符，跳过累积（否则累出乱码 id）。
DWORD WINAPI Detour_GetGlyphOutlineW(HDC hdc, UINT uChar, UINT uFormat,
                                     LPGLYPHMETRICS lpgm, DWORD cbBuffer,
                                     LPVOID lpvBuffer, const MAT2* lpmat2) {
  if (g_capture_enabled && g_text_cs_ready &&
      (uFormat & GGO_GLYPH_INDEX) == 0) {
    EnterCriticalSection(&g_text_cs);
    const ULONGLONG now = GetTickCount64();
    if (g_glyph_len > 0 && (now - g_glyph_last_tick) > 120) {
      FlushGlyphAccumLocked();  // 时间空隙 -> 行界
    }
    if (uChar != 0 && uChar <= 0xFFFFu) {
      if (g_glyph_len >= kMaxLineChars) {
        FlushGlyphAccumLocked();  // 缓冲将满 -> 强制 flush
      }
      g_glyph_buf[g_glyph_len++] = static_cast<wchar_t>(uChar);
    }
    g_glyph_last_tick = now;
    LeaveCriticalSection(&g_text_cs);
  }
  return g_orig_GetGlyphOutlineW(hdc, uChar, uFormat, lpgm, cbBuffer, lpvBuffer,
                                 lpmat2);
}

// -- detour: ExtTextOutW / TextOutW（gdi32）+ DrawTextW（user32）--
// lpString + 字符数即整串台词，直接成一行（补 GetGlyphOutline 抓不到的整串渲染）。先冲掉逐字
// 累积再写整串，避免行被拆。ETO_GLYPH_INDEX（字形索引非字符）/ DT_CALCRECT（只测量不渲染）等
// 非真实文本内容跳过。
BOOL WINAPI Detour_ExtTextOutW(HDC hdc, int x, int y, UINT options,
                               const RECT* lprect, LPCWSTR lpString, UINT c,
                               const INT* lpDx) {
  if (g_capture_enabled && g_text_cs_ready && lpString != nullptr && c > 0 &&
      (options & ETO_GLYPH_INDEX) == 0) {
    EnterCriticalSection(&g_text_cs);
    FlushGlyphAccumLocked();
    FlushLineLocked(lpString, static_cast<int>(c));
    LeaveCriticalSection(&g_text_cs);
  }
  return g_orig_ExtTextOutW(hdc, x, y, options, lprect, lpString, c, lpDx);
}

BOOL WINAPI Detour_TextOutW(HDC hdc, int x, int y, LPCWSTR lpString, int c) {
  if (g_capture_enabled && g_text_cs_ready && lpString != nullptr && c > 0) {
    EnterCriticalSection(&g_text_cs);
    FlushGlyphAccumLocked();
    FlushLineLocked(lpString, c);
    LeaveCriticalSection(&g_text_cs);
  }
  return g_orig_TextOutW(hdc, x, y, lpString, c);
}

int WINAPI Detour_DrawTextW(HDC hdc, LPCWSTR lpchText, int cchText, LPRECT lprc,
                            UINT format) {
  if (g_capture_enabled && g_text_cs_ready && lpchText != nullptr &&
      (format & DT_CALCRECT) == 0) {
    int len = cchText;
    if (len < 0) {
      // cchText<0：以 NUL 结尾；手数长度（避免依赖 wcsnlen）。
      len = 0;
      while (len < kMaxLineChars && lpchText[len] != 0) {
        len++;
      }
    }
    if (len > 0) {
      EnterCriticalSection(&g_text_cs);
      FlushGlyphAccumLocked();
      FlushLineLocked(lpchText, len);
      LeaveCriticalSection(&g_text_cs);
    }
  }
  return g_orig_DrawTextW(hdc, lpchText, cchText, lprc, format);
}

// 装文本渲染 hook：gdi32 的 GetGlyphOutlineW/ExtTextOutW/TextOutW + user32 的 DrawTextW
// （GetModuleHandle 取已加载模块，未加载则 LoadLibrary 强制解析导出）。装在 XAudio2/
// DirectSound hook 之后（见 HookWorker）。
void TryHookTextRender() {
  HMODULE gdi = GetModuleHandleW(L"gdi32.dll");
  if (gdi == nullptr) {
    gdi = LoadLibraryW(L"gdi32.dll");
  }
  if (gdi != nullptr) {
    HookFn(reinterpret_cast<void*>(GetProcAddress(gdi, "GetGlyphOutlineW")),
           reinterpret_cast<void*>(&Detour_GetGlyphOutlineW),
           reinterpret_cast<void**>(&g_orig_GetGlyphOutlineW));
    HookFn(reinterpret_cast<void*>(GetProcAddress(gdi, "ExtTextOutW")),
           reinterpret_cast<void*>(&Detour_ExtTextOutW),
           reinterpret_cast<void**>(&g_orig_ExtTextOutW));
    HookFn(reinterpret_cast<void*>(GetProcAddress(gdi, "TextOutW")),
           reinterpret_cast<void*>(&Detour_TextOutW),
           reinterpret_cast<void**>(&g_orig_TextOutW));
  }
  HMODULE usr = GetModuleHandleW(L"user32.dll");
  if (usr == nullptr) {
    usr = LoadLibraryW(L"user32.dll");
  }
  if (usr != nullptr) {
    HookFn(reinterpret_cast<void*>(GetProcAddress(usr, "DrawTextW")),
           reinterpret_cast<void*>(&Detour_DrawTextW),
           reinterpret_cast<void**>(&g_orig_DrawTextW));
  }
}
