#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <string>

#include "voice_hook_ipc.h"

// galgame 一键制卡 C 阶段 hook DLL（C.1：注入 + IPC proof-of-life）。
//
// 本切片建立注入管线与共享内存契约：注入进游戏后打开 injector 建好的共享内存、标记
// hooked=1、SetEvent 通知 injector 注入成功。**实际的 XAudio2/DirectSound 语音捕获 hook 是
// C.2**（在 HookWorker 的标注处安装，需真实 galgame 验证，此切片不做——写没法验证的 hook 代码
// 是 slop）。
//
// loader lock 纪律：DllMain 里**不**做 IPC/同步/加载库，只 DisableThreadLibraryCalls +
// CreateThread 把活儿丢给工作线程（在 loader lock 之外跑），这是 hook DLL 的正确形态。
namespace {

using hibiki_voice_hook::kSharedMagic;
using hibiki_voice_hook::kSharedVersion;
using hibiki_voice_hook::ReadyEventName;
using hibiki_voice_hook::SharedHeader;
using hibiki_voice_hook::SharedMemoryName;

HANDLE g_mapping = nullptr;
SharedHeader* g_header = nullptr;
volatile bool g_stop = false;

// 独立测试用 proof-of-life 标记文件：%TEMP%\hibiki_voice_hook_<pid>.marker。injector 之外也
// 能据此确认 DLL 真的被加载执行（不依赖事件）。
void WriteMarkerFile(DWORD pid) {
  wchar_t temp[MAX_PATH] = {0};
  const DWORD n = GetTempPathW(MAX_PATH, temp);
  if (n == 0 || n > MAX_PATH) {
    return;
  }
  std::wstring path =
      std::wstring(temp) + L"hibiki_voice_hook_" + std::to_wstring(pid) +
      L".marker";
  HANDLE f = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                         CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (f == INVALID_HANDLE_VALUE) {
    return;
  }
  const char msg[] = "hibiki voice hook attached\n";
  DWORD written = 0;
  WriteFile(f, msg, sizeof(msg) - 1, &written, nullptr);
  CloseHandle(f);
}

// 工作线程：打开 injector 建好的共享内存 → 校验契约 → 标记 hooked → 通知 injector。
DWORD WINAPI HookWorker(LPVOID) {
  const DWORD pid = GetCurrentProcessId();
  WriteMarkerFile(pid);

  const std::wstring shm = SharedMemoryName(pid);
  g_mapping = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, shm.c_str());
  if (g_mapping != nullptr) {
    g_header = static_cast<SharedHeader*>(
        MapViewOfFile(g_mapping, FILE_MAP_ALL_ACCESS, 0, 0, 0));
  }
  if (g_header != nullptr) {
    // 只信任 injector 建好、契约匹配的映射。
    if (g_header->magic == kSharedMagic &&
        g_header->version == kSharedVersion) {
      g_header->hooked = 1;

      // ── C.2 挂钩点（此切片不做，需真实 galgame 验证）──────────────────────
      // 这里安装 XAudio2 / DirectSound 的 vtable hook（经 MinHook 之类）：
      //   1. hook IXAudio2::CreateSourceVoice 包裹每个 source voice；
      //   2. hook IXAudio2SourceVoice::SubmitSourceBuffer——在语音进混音前，把
      //      XAUDIO2_BUFFER.pAudioData 的 [PlayBegin, PlayLength) 段 memcpy 进
      //      header 之后的环形缓冲（回调里只 memcpy + 更新 write_pos/total_written，
      //      写盘/编码/IPC 全部移出——回调阻塞即爆音，spec 红线）；
      //   3. 首次拿到语音 WAVEFORMATEX 时填 header 的 sample_rate/channels/
      //      bits_per_sample/is_float/block_align；
      //   4. 校准模式（header->calibrating）：识别角色语音的 voice callsite
      //      （首次抓一次调用栈，记 game.exe SHA + callsite RVA），正常模式只比对 RVA。
      // ────────────────────────────────────────────────────────────────────
    }
  }

  // 通知 injector：DLL 已加载并跑到这里（proof-of-life）。事件由 injector 建好。
  const std::wstring evt = ReadyEventName(pid);
  HANDLE ready = OpenEventW(EVENT_MODIFY_STATE, FALSE, evt.c_str());
  if (ready != nullptr) {
    SetEvent(ready);
    CloseHandle(ready);
  }

  // C.2 起：此线程承载捕获期间的聚合/生命周期。C.1 保活到卸载即可。
  while (!g_stop) {
    Sleep(200);
  }
  return 0;
}

}  // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
  switch (reason) {
    case DLL_PROCESS_ATTACH:
      DisableThreadLibraryCalls(module);
      // 活儿丢给工作线程（loader lock 之外）。CreateThread 在 DllMain 中是允许的。
      CreateThread(nullptr, 0, HookWorker, nullptr, 0, nullptr);
      break;
    case DLL_PROCESS_DETACH:
      g_stop = true;
      if (g_header != nullptr) {
        UnmapViewOfFile(g_header);
        g_header = nullptr;
      }
      if (g_mapping != nullptr) {
        CloseHandle(g_mapping);
        g_mapping = nullptr;
      }
      break;
    default:
      break;
  }
  return TRUE;
}
