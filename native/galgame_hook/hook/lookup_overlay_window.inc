// P1 split: included inside dll_main.cpp anonymous namespace.
// ══ 通用位图呈现器：注入进程内的分层置顶窗口 ══════════════════════════════════════
//
// 游戏内查词的卡片位图此前只有 KiriKiri 的 TJS Layer 一条落地路径。有脚本宿主的引擎只此
// 一家；CMVS / Siglus / Ren'Py / Unity / AOS 都没有等价物，于是这些引擎上 hit / input /
// frame 三通道和整条 Dart 编排层都是通的，唯独最后一步没有承载物。
//
// 为什么是分层窗口而不是 hook D3D Present：
//   * Present 钩子要按 D3D9 / D3D11 / OpenGL / 自绘 GDI 各写一份，且踩在保护壳最敏感的
//     位置上（这批游戏里 Siglus 带 Enigma、AOS 带 ddraw 兼容层），崩在游戏渲染线程上
//     的代价是整局丢失；
//   * 分层窗口一份代码覆盖全部引擎，不碰游戏的渲染路径一根指针，最坏情况是窗口没显示，
//     游戏本身不受影响。
//   * 代价诚实写在这里：**独占全屏（exclusive fullscreen）下盖不住游戏**。绝大多数
//     galgame 是窗口或无边框窗口，独占全屏的那部分只能退回游戏外浮窗。
//
// 线程模型：自带 UI 线程与消息循环。绝不在游戏线程上建窗口——那会把我们的消息循环塞进
// 游戏的循环里，任何一次阻塞都变成游戏卡死。
//
// 与 KiriKiri 路径的关系：互斥。引擎适配器认领呈现器后（ClaimLookupPresenter），通用
// 呈现器不启动；KiriKiri 仍走它自己的 Layer，因为在游戏渲染树里跟随全屏与窗口变换是分层
// 窗口做不到的。

// 注意：本文件被 include 进 dll_main.cpp 的**匿名命名空间内部**，所以这里一行 #include
// 都不能有。头文件里的 `namespace fushi_voice_hook` 会在匿名命名空间里再开一个同名的
// 嵌套命名空间，把真正的 ::fushi_voice_hook 整个遮住——症状是本文件之后的每个 adapter
// 都报「不是 fushi_voice_hook 的成员」，而错误行全在别人家里。lookup_overlay_geometry.h
// 由 dll_main.cpp 在文件作用域引入。

// 引擎适配器已认领呈现（KiriKiri 的 TJS Layer）。通用呈现器只在无人认领时启动。
volatile LONG g_lookup_presenter_claimed = 0;

void ClaimLookupPresenter() {
  InterlockedExchange(&g_lookup_presenter_claimed, 1);
}

constexpr UINT_PTR kOverlayTimerId = 1;
constexpr UINT kOverlayTimerMs = 16;  // 约 60Hz：卡片是静态位图，不需要更快

struct LookupOverlayState {
  HWND window = nullptr;
  HWND owner = nullptr;
  HANDLE thread = nullptr;
  DWORD thread_id = 0;
  // 已经处理过的**帧发布序**（LookupFrame::seq），不是 lookup_frame_count_written。
  // 这两个数曾被混为一谈，代价见 PollOverlayFrame 里的长注释。
  uint64_t last_presented_seq = 0;
  fushi_voice_hook::OverlayRect card;
  bool visible = false;
  bool tracking_mouse = false;
  std::vector<uint8_t> pixels;  // 预乘后的 BGRA，UI 线程私有
};

LookupOverlayState g_overlay;

uint64_t ReadOverlaySharedU64(volatile uint64_t* value) {
  return static_cast<uint64_t>(InterlockedCompareExchange64(
      reinterpret_cast<volatile LONG64*>(value), 0, 0));
}

void WriteOverlaySharedU64(volatile uint64_t* value, uint64_t next) {
  InterlockedExchange64(reinterpret_cast<volatile LONG64*>(value),
                        static_cast<LONG64>(next));
}

// 把一个输入事件写进查词输入环。写序与 kirikiri 那条完全一致：先填 payload，**最后**写
// seq，再推进计数。坐标必须已经是卡片局部坐标。
void QueueOverlayInput(uint32_t kind, int32_t x, int32_t y, int32_t wheel,
                       uint32_t keys) {
  if (g_header == nullptr) return;
  fushi_voice_hook::LookupInputSlot* inputs =
      fushi_voice_hook::LookupInputsOf(g_header);
  const uint32_t slots = g_header->lookup_input_slot_count;
  if (inputs == nullptr || slots == 0) return;
  const uint64_t next = ReadOverlaySharedU64(&g_header->lookup_input_count) + 1;
  fushi_voice_hook::LookupInputSlot* slot = &inputs[(next - 1) % slots];
  slot->x = x;
  slot->y = y;
  slot->kind = kind;
  slot->wheel = wheel;
  slot->keys = keys;
  slot->reserved = 0;
  WriteOverlaySharedU64(&slot->seq, next);
  WriteOverlaySharedU64(&g_header->lookup_input_count, next);
}

uint32_t OverlayModifierKeys() {
  uint32_t keys = 0;
  if ((GetKeyState(VK_SHIFT) & 0x8000) != 0) keys |= 1u;
  if ((GetKeyState(VK_CONTROL) & 0x8000) != 0) keys |= 2u;
  if ((GetKeyState(VK_MENU) & 0x8000) != 0) keys |= 4u;
  return keys;
}

// 客户区在屏幕上的矩形。窗口已销毁或最小化时返回空。
fushi_voice_hook::OverlayRect OwnerClientRect(HWND owner) {
  fushi_voice_hook::OverlayRect result;
  if (owner == nullptr || IsIconic(owner) || !IsWindow(owner)) return result;
  RECT client = {};
  if (!GetClientRect(owner, &client)) return result;
  POINT origin = {client.left, client.top};
  if (!ClientToScreen(owner, &origin)) return result;
  result.left = origin.x;
  result.top = origin.y;
  result.right = origin.x + (client.right - client.left);
  result.bottom = origin.y + (client.bottom - client.top);
  return result;
}

struct OwnerSearch {
  DWORD pid = 0;
  HWND best = nullptr;
  long best_area = 0;
};

BOOL CALLBACK FindOverlayOwner(HWND window, LPARAM param) {
  OwnerSearch* search = reinterpret_cast<OwnerSearch*>(param);
  DWORD pid = 0;
  GetWindowThreadProcessId(window, &pid);
  if (pid != search->pid) return TRUE;
  if (!IsWindowVisible(window)) return TRUE;
  if (GetWindow(window, GW_OWNER) != nullptr) return TRUE;  // 只要顶层主窗口
  RECT rect = {};
  if (!GetClientRect(window, &rect)) return TRUE;
  const long area = static_cast<long>(rect.right - rect.left) *
                    static_cast<long>(rect.bottom - rect.top);
  // 最大的可见顶层窗口就是游戏主窗口。启动器/工具窗口都比它小。
  if (area > search->best_area) {
    search->best_area = area;
    search->best = window;
  }
  return TRUE;
}

HWND FindGameMainWindow() {
  OwnerSearch search;
  search.pid = GetCurrentProcessId();
  EnumWindows(&FindOverlayOwner, reinterpret_cast<LPARAM>(&search));
  return search.best;
}

void HideOverlay() {
  if (!g_overlay.visible) return;
  g_overlay.visible = false;
  g_overlay.card = fushi_voice_hook::OverlayRect();
  if (g_overlay.window != nullptr) ShowWindow(g_overlay.window, SW_HIDE);
}

// 把 host 的 BGRA 搬成 UpdateLayeredWindow 要的**预乘** BGRA。
//
// host 侧（离屏 WebView2 → 共享内存）给的是非预乘 BGRA：KiriKiri 那条路径把它直接 memcpy
// 进 ltAlpha 的 Layer，而 KiriKiri 的 alpha 也是非预乘的。UpdateLayeredWindow 配
// AC_SRC_ALPHA 则要求预乘，不乘的话半透明边缘会发白。这一步只在真有新帧时跑，卡片尺寸级别。
void PremultiplyInto(std::vector<uint8_t>* target, const uint8_t* source,
                     uint32_t width, uint32_t height, uint32_t pitch) {
  const size_t needed = static_cast<size_t>(width) * height * 4u;
  target->resize(needed);
  uint8_t* out = target->data();
  for (uint32_t y = 0; y < height; ++y) {
    const uint8_t* row = source + static_cast<size_t>(y) * pitch;
    for (uint32_t x = 0; x < width; ++x) {
      const uint8_t b = row[x * 4 + 0];
      const uint8_t g = row[x * 4 + 1];
      const uint8_t r = row[x * 4 + 2];
      const uint8_t a = row[x * 4 + 3];
      out[0] = static_cast<uint8_t>((b * a + 127) / 255);
      out[1] = static_cast<uint8_t>((g * a + 127) / 255);
      out[2] = static_cast<uint8_t>((r * a + 127) / 255);
      out[3] = a;
      out += 4;
    }
  }
}

// 把当前 pixels 推到分层窗口上。card 必须已算好。
bool PresentOverlayBitmap(uint32_t width, uint32_t height) {
  if (g_overlay.window == nullptr) return false;
  if (width == 0 || height == 0) return false;
  HDC screen = GetDC(nullptr);
  if (screen == nullptr) return false;
  HDC memory = CreateCompatibleDC(screen);
  if (memory == nullptr) {
    ReleaseDC(nullptr, screen);
    return false;
  }
  BITMAPINFO info = {};
  info.bmiHeader.biSize = sizeof(info.bmiHeader);
  info.bmiHeader.biWidth = static_cast<LONG>(width);
  // 负高度 = 自顶向下。IPC 契约里 pitch 恒为正、恒自顶向下，这里跟着它走。
  info.bmiHeader.biHeight = -static_cast<LONG>(height);
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HBITMAP bitmap =
      CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  bool ok = false;
  if (bitmap != nullptr && bits != nullptr) {
    memcpy(bits, g_overlay.pixels.data(),
           std::min<size_t>(g_overlay.pixels.size(),
                            static_cast<size_t>(width) * height * 4u));
    HGDIOBJ previous = SelectObject(memory, bitmap);
    POINT position = {g_overlay.card.left, g_overlay.card.top};
    SIZE size = {static_cast<LONG>(width), static_cast<LONG>(height)};
    POINT source = {0, 0};
    BLENDFUNCTION blend = {};
    blend.BlendOp = AC_SRC_OVER;
    blend.SourceConstantAlpha = 255;
    blend.AlphaFormat = AC_SRC_ALPHA;
    ok = UpdateLayeredWindow(g_overlay.window, screen, &position, &size, memory,
                             &source, 0, &blend, ULW_ALPHA) != FALSE;
    SelectObject(memory, previous);
  }
  if (bitmap != nullptr) DeleteObject(bitmap);
  DeleteDC(memory);
  ReleaseDC(nullptr, screen);
  return ok;
}

// 读一帧并显示。返回 false 表示这轮没有可用新帧（不是错误）。
void PollOverlayFrame() {
  // 认领是**每帧复查**的，不是只在启动时问一次。真机实测（tenshi_sz，KiriKiri Z）：host 把
  // lookup_enabled 拨到 1 的时刻早于 KiriKiri 拿到 TJS exporter，于是通用呈现器先起了线程，
  // 随后 KiriKiri 才认领——只在 StartLookupOverlayIfUnclaimed 里判一次的话，这一局就会有
  // 两个呈现器同时贴同一帧，用户看到双份卡片。
  // 让位而不是退出线程：认领可能发生在任意一帧，线程留着最省事，隐藏后它只是空转。
  if (InterlockedCompareExchange(&g_lookup_presenter_claimed, 0, 0) != 0) {
    HideOverlay();
    return;
  }
  if (g_header == nullptr || !fushi_voice_hook::HasLookupRegion(g_header)) return;
  if (g_header->lookup_enabled == 0) {
    HideOverlay();
    return;
  }
  const uint32_t frame_count = g_header->lookup_frame_count;
  if (frame_count == 0) return;

  // 选帧：**扫全部槽、按帧自己的发布序挑最新的一张**，绝不从 lookup_frame_count_written
  // 反推槽下标。
  //
  // 为什么这条必须写死：槽下标是契约的一部分——host 用的是 `帧发布序 % lookup_frame_count`
  // （voice_hook_reader.cpp 的 WriteLookupFrame，注释里明写"两处共用同一个 index"）。
  // 而 written 与发布序虽然同步递增，`(written - 1) % frame_count` 恒好比它小 1：
  // host 写槽 seq%2，这里就读槽 (seq-1)%2 —— 双缓冲下**永远读的是另一个槽**，
  // 第一帧读到的是全零槽（ready=0）直接 return，于是卡片一辈子不出现。
  // 更毒的是这个症状与「host 压根没投帧」完全同形，真机上分不开（契约头的注释就是
  // 为这件事写的）。KiriKiri 那条路径从来是扫全槽按 seq 选，所以躲过了这一劫。
  fushi_voice_hook::LookupFrame* frame = nullptr;
  uint32_t frame_index = 0;
  uint64_t seq_before = 0;
  for (uint32_t i = 0; i < frame_count; ++i) {
    fushi_voice_hook::LookupFrame* candidate =
        fushi_voice_hook::LookupFrameAt(g_header, i);
    if (candidate == nullptr) continue;
    if (candidate->ready == 0) continue;  // host 正在写这一槽
    const uint64_t seq = ReadOverlaySharedU64(&candidate->seq);
    if (seq <= g_overlay.last_presented_seq) continue;  // 处理过了
    if (seq <= seq_before) continue;                    // 已有更新的候选
    frame = candidate;
    frame_index = i;
    seq_before = seq;
  }
  if (frame == nullptr) {
    // 没有新帧。窗口跟随：游戏窗口被拖动/缩放时卡片要跟着走，否则它会留在屏幕原地。
    if (g_overlay.visible) {
      const fushi_voice_hook::OverlayRect client = OwnerClientRect(g_overlay.owner);
      if (client.empty()) {
        HideOverlay();
      }
    }
    return;
  }

  if ((frame->flags & fushi_voice_hook::kLookupFrameDismiss) != 0) {
    g_overlay.last_presented_seq = seq_before;
    HideOverlay();
    return;
  }
  // 跨进程不可信的 width/height/pitch 必须先过这道闸门再谈拷贝。
  if (!fushi_voice_hook::IsLookupFrameSane(g_header, frame)) {
    g_overlay.last_presented_seq = seq_before;
    g_header->lookup_diag |= fushi_voice_hook::kLookupDiagFrameRejected;
    return;
  }
  const uint8_t* pixels =
      fushi_voice_hook::LookupBitmapAt(g_header, frame_index);
  if (pixels == nullptr) return;

  const uint32_t width = frame->width;
  const uint32_t height = frame->height;
  const uint32_t pitch = frame->pitch;
  const int32_t anchor_x = frame->anchor_x;
  const int32_t anchor_y = frame->anchor_y;
  PremultiplyInto(&g_overlay.pixels, pixels, width, height, pitch);
  // 拷完复查 seq/ready 未变，否则这帧是撕裂的，丢掉。
  if (ReadOverlaySharedU64(&frame->seq) != seq_before || frame->ready == 0) {
    return;
  }

  if (g_overlay.owner == nullptr || !IsWindow(g_overlay.owner)) {
    g_overlay.owner = FindGameMainWindow();
  }
  const fushi_voice_hook::OverlayRect client = OwnerClientRect(g_overlay.owner);
  const fushi_voice_hook::OverlayRect card = fushi_voice_hook::ComputeOverlayRect(
      client, anchor_x, anchor_y, static_cast<int32_t>(width),
      static_cast<int32_t>(height));
  g_overlay.last_presented_seq = seq_before;
  if (card.empty()) {
    HideOverlay();
    return;
  }
  g_overlay.card = card;
  if (!PresentOverlayBitmap(static_cast<uint32_t>(card.width()),
                            static_cast<uint32_t>(card.height()))) {
    return;
  }
  if (!g_overlay.visible) {
    g_overlay.visible = true;
    // SW_SHOWNOAUTO... 不抢激活：WS_EX_NOACTIVATE + SW_SHOWNA。
    ShowWindow(g_overlay.window, SW_SHOWNA);
  }
  SetWindowPos(g_overlay.window, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  if (g_header != nullptr) {
    g_header->lookup_diag |= fushi_voice_hook::kLookupDiagFramePresented;
  }
}

LRESULT CALLBACK LookupOverlayProc(HWND window, UINT message, WPARAM wparam,
                                   LPARAM lparam) {
  switch (message) {
    case WM_TIMER:
      if (wparam == kOverlayTimerId) {
        PollOverlayFrame();
        return 0;
      }
      break;
    case WM_MOUSEMOVE: {
      if (!g_overlay.tracking_mouse) {
        TRACKMOUSEEVENT track = {};
        track.cbSize = sizeof(track);
        track.dwFlags = TME_LEAVE;
        track.hwndTrack = window;
        if (TrackMouseEvent(&track)) g_overlay.tracking_mouse = true;
      }
      QueueOverlayInput(fushi_voice_hook::kLookupInputMove,
                        GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam), 0,
                        OverlayModifierKeys());
      return 0;
    }
    case WM_MOUSELEAVE:
      g_overlay.tracking_mouse = false;
      QueueOverlayInput(fushi_voice_hook::kLookupInputLeave, 0, 0, 0, 0);
      return 0;
    case WM_LBUTTONDOWN:
      QueueOverlayInput(fushi_voice_hook::kLookupInputLeftDown,
                        GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam), 0,
                        OverlayModifierKeys());
      return 0;
    case WM_LBUTTONUP:
      QueueOverlayInput(fushi_voice_hook::kLookupInputLeftUp,
                        GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam), 0,
                        OverlayModifierKeys());
      return 0;
    case WM_MOUSEWHEEL: {
      // 滚轮消息带的是屏幕坐标，与其它鼠标消息不同，必须换算回卡片局部坐标。
      POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      int32_t local_x = 0;
      int32_t local_y = 0;
      fushi_voice_hook::ScreenPointToCardLocal(g_overlay.card, point.x, point.y,
                                               &local_x, &local_y);
      QueueOverlayInput(fushi_voice_hook::kLookupInputWheel, local_x, local_y,
                        GET_WHEEL_DELTA_WPARAM(wparam), OverlayModifierKeys());
      return 0;
    }
    // 分层窗口自己不画背景，也绝不接受激活：抢了焦点就等于把游戏切到后台。
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    case WM_ERASEBKGND:
      return 1;
    default:
      break;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

DWORD WINAPI LookupOverlayThread(LPVOID) {
  WNDCLASSEXW wc = {};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = &LookupOverlayProc;
  wc.hInstance = g_module;
  wc.lpszClassName = L"FushiLookupOverlay";
  wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  if (RegisterClassExW(&wc) == 0 && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    return 0;
  }
  g_overlay.window = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
      wc.lpszClassName, L"", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr, g_module,
      nullptr);
  if (g_overlay.window == nullptr) return 0;
  SetTimer(g_overlay.window, kOverlayTimerId, kOverlayTimerMs, nullptr);

  MSG message = {};
  while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
  KillTimer(g_overlay.window, kOverlayTimerId);
  DestroyWindow(g_overlay.window);
  g_overlay.window = nullptr;
  return 0;
}

// 启动通用呈现器。引擎适配器已认领呈现时直接返回——两条路径同时显示卡片会出现双份。
void StartLookupOverlayIfUnclaimed() {
  if (InterlockedCompareExchange(&g_lookup_presenter_claimed, 0, 0) != 0) return;
  if (g_overlay.thread != nullptr) return;
  g_overlay.thread =
      CreateThread(nullptr, 0, &LookupOverlayThread, nullptr, 0, &g_overlay.thread_id);
}

void StopLookupOverlay() {
  if (g_overlay.thread == nullptr) return;
  if (g_overlay.thread_id != 0) {
    PostThreadMessageW(g_overlay.thread_id, WM_QUIT, 0, 0);
  }
  // DllMain 的 loader lock 下不能无限等线程；给一个有界等待，超时就放手（进程即将退出）。
  WaitForSingleObject(g_overlay.thread, 2000);
  CloseHandle(g_overlay.thread);
  g_overlay.thread = nullptr;
  g_overlay.thread_id = 0;
}
