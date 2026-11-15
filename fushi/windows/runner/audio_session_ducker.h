#ifndef RUNNER_AUDIO_SESSION_DUCKER_H_
#define RUNNER_AUDIO_SESSION_DUCKER_H_

#include <windows.h>

#include <audiopolicy.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>
#include <wrl/implements.h>

#include <map>
#include <mutex>
#include <set>
#include <string>
#include <vector>

#include "audio_duck_gain.h"

// 按进程树压低 / 还原 / 探测 Windows 音频会话音量（约定见 audio_duck_gain.h）。
// runner（网页视频制卡 silent、游戏串流静音主机）与 flutter_webrtc 插件（串流采集侧
// 探测压低状态）共用这一份。COM 调用都要求调用线程已 CoInitializeEx(MTA)。
// 纯 HRESULT 校验、不抛异常（runner 以 _HAS_EXCEPTIONS=0 编译）。
namespace fushi {

// [root] 及其全部后代进程 id。
std::set<DWORD> ProcessTree(DWORD root);

// 全部活动渲染端点的会话管理器（游戏 / 浏览器不一定渲染到默认端点）。
std::vector<Microsoft::WRL::ComPtr<IAudioSessionManager2>>
OpenRenderSessionManagers();

// 把 [tree] 里停在压低值上的会话（上次压低没走到还原：进程被杀；Windows 按可执行文件
// 持久化会话音量）还原到 1.0。返回还原的会话数。
int RestoreResidualDuckedSessions(
    const std::vector<Microsoft::WRL::ComPtr<IAudioSessionManager2>>& managers,
    const std::set<DWORD>& tree);

// 一个被压低的会话：还原时写回 [original]。
struct DuckedSession {
  Microsoft::WRL::ComPtr<ISimpleAudioVolume> volume;
  float original = 1.0f;
};

// 对一组渲染端点上属于目标进程树的会话做「压低 / 还原」。线程安全（mutex_），因为
// IAudioSessionNotification 回调在系统线程上来。
class SessionDucker {
 public:
  void Open() { managers_ = OpenRenderSessionManagers(); }

  void SetTree(DWORD root, std::set<DWORD> tree);

  // 扫一遍全部会话：树内的压到 kSilentDuckLevel（首次见到时记下原音量）。
  void DuckAll();

  // 单个会话（扫描或新建通知）：属于目标树就压低。
  void Duck(IAudioSessionControl* control);

  void RestoreAll();

  const std::vector<Microsoft::WRL::ComPtr<IAudioSessionManager2>>& managers()
      const {
    return managers_;
  }

 private:
  std::vector<Microsoft::WRL::ComPtr<IAudioSessionManager2>> managers_;
  std::mutex mutex_;
  DWORD root_ = 0;
  std::set<DWORD> tree_;
  std::set<DWORD> foreign_;  // 已确认不属于目标树的会话进程
  std::map<std::wstring, DuckedSession> ducked_;
};

// 新会话一建立就压低（按需起的音频进程；等兜底扫描会漏掉开头一截）。
class DuckOnCreate
    : public Microsoft::WRL::RuntimeClass<
          Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
          Microsoft::WRL::FtmBase, IAudioSessionNotification> {
 public:
  explicit DuckOnCreate(SessionDucker* ducker) : ducker_(ducker) {}
  STDMETHOD(OnSessionCreated)(IAudioSessionControl* session) override {
    if (session != nullptr) {
      ducker_->Duck(session);
    }
    return S_OK;
  }

 private:
  SessionDucker* ducker_;
};

// 采集侧：目标进程树的会话此刻是否处在压低值上。只读，不改任何音量。
// 会话列表与进程树由 Refresh 重扫（建议 ~1 s 一次），Ducked 只读缓存会话的当前音量
// （可高频调用）。单线程使用。
class DuckedTreeProbe {
 public:
  void Open(DWORD root);
  void Refresh();
  bool Ducked() const;
  // 释放全部 COM 引用（须在 CoUninitialize 之前、同一线程上调用）。
  void Close();

 private:
  DWORD root_ = 0;
  std::vector<Microsoft::WRL::ComPtr<IAudioSessionManager2>> managers_;
  std::vector<Microsoft::WRL::ComPtr<ISimpleAudioVolume>> volumes_;
};

}  // namespace fushi

#endif  // RUNNER_AUDIO_SESSION_DUCKER_H_
