#ifndef RUNNER_WGC_INTEROP_H_
#define RUNNER_WGC_INTEROP_H_

#include <windows.h>

#include <roapi.h>
#include <winstring.h>

#include <wrl/client.h>

#include <windows.foundation.h>
#include <windows.graphics.capture.h>

#include <cwchar>

// Windows.Graphics.Capture 纯 WRL/ABI 互操作小件，供单帧截图（window_capture.cpp）
// 与持续录制（window_recorder.cpp）共用。runner 以 _HAS_EXCEPTIONS=0 编译，故不用
// C++/WinRT 投影类型，全程 HRESULT 校验、不抛异常。
namespace fushi {
namespace wgc {

// 与 Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess 同 IID，
// 本地声明避免依赖系统 interop 头在非 cppwinrt 构建下暴露它。用于从 WinRT surface
// 取回底层 ID3D11Texture2D。
struct __declspec(uuid("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1"))
    IDxgiInterfaceAccessLocal : public ::IUnknown {
  virtual HRESULT __stdcall GetInterface(REFIID id, void** object) = 0;
};

// RoGetActivationFactory 薄封装：用类名的 WCHAR 字面量取激活工厂接口 [I]。
template <typename I>
HRESULT GetActivationFactory(const wchar_t* class_name, I** out) {
  HSTRING str = nullptr;
  HSTRING_HEADER header;
  HRESULT hr = WindowsCreateStringReference(
      class_name, static_cast<UINT32>(wcslen(class_name)), &header, &str);
  if (FAILED(hr)) {
    return hr;
  }
  return RoGetActivationFactory(str, __uuidof(I),
                                reinterpret_cast<void**>(out));
}

// 关闭实现 IClosable 的 WinRT 对象（frame / session / framePool），确定性拆除
// （不赌析构时序；与本仓 WGC 生命周期纪律一致）。
template <typename T>
void CloseIfClosable(const Microsoft::WRL::ComPtr<T>& obj) {
  if (!obj) {
    return;
  }
  Microsoft::WRL::ComPtr<ABI::Windows::Foundation::IClosable> closable;
  if (SUCCEEDED(obj.As(&closable))) {
    closable->Close();
  }
}

// 去掉 WGC 在被捕获窗口四周画的黄色高亮框，返回 put_IsBorderRequired(false) 的
// HRESULT。IGraphicsCaptureSession3 是 Windows build 20348 才有的接口（Windows 10
// 22H2 = 19045 没有）：缺它时返回 E_NOINTERFACE，此时黄框**应用无法关闭**，由调用方
// 决定这次捕获还值不值得做——短暂的单帧截图可以接受一闪，持续整局的会话不行。
// 非打包桌面应用无需先 GraphicsCaptureAccess::RequestAccessAsync(Borderless)
// （Windows 11 上实测裸 put 即 S_OK、读回 false）。
inline HRESULT SuppressCaptureBorder(
    ABI::Windows::Graphics::Capture::IGraphicsCaptureSession* session) {
  if (session == nullptr) {
    return E_POINTER;
  }
  Microsoft::WRL::ComPtr<ABI::Windows::Graphics::Capture::IGraphicsCaptureSession3>
      session3;
  const HRESULT qi = session->QueryInterface(IID_PPV_ARGS(&session3));
  if (FAILED(qi) || !session3) {
    return E_NOINTERFACE;
  }
  return session3->put_IsBorderRequired(false);
}

}  // namespace wgc
}  // namespace fushi

#endif  // RUNNER_WGC_INTEROP_H_
