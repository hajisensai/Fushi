#ifndef RUNNER_WGC_INTEROP_H_
#define RUNNER_WGC_INTEROP_H_

#include <windows.h>

#include <roapi.h>
#include <winstring.h>

#include <wrl/client.h>

#include <windows.foundation.h>

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

}  // namespace wgc
}  // namespace fushi

#endif  // RUNNER_WGC_INTEROP_H_
