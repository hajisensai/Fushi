#pragma once

#include <d3d11.h>
#include <windows.h>

#include <memory>
#include <string>
#include <vector>

namespace flutter_inappwebview_plugin
{
  // 计划 P2：在 WGC 抓到的页面帧（src）→ Flutter 共享纹理（dst）之间插一段 libplacebo
  // D3D11 渲染通道，跑 mpv 用户着色器（Anime4K 各档 .glsl）。
  //
  // libplacebo 运行期 LoadLibrary 动态加载（third_party/libplacebo-win 随包 DLL），不链接导入库：
  // DLL 缺失 / 设备不支持 / 着色器解析失败一律 fail-open —— Create() 回 nullptr 或 Render() 回
  // false，调用方退回原样 CopyResource。所有方法都在持有 TextureBridge::mutex_ 的线程上调用。
  class PlaceboPass {
  public:
    // device 是 WGC 帧池与共享纹理所在的 D3D11 设备（GraphicsContext::d3d_device）。
    static std::unique_ptr<PlaceboPass> Create(ID3D11Device* device);
    ~PlaceboPass();

    // 替换着色器链（mpv .glsl 文本，按应用顺序）。空 = 直通。回 true 表示全部解析成功；
    // 解析失败的条目被跳过（记日志）。
    bool SetShaders(const std::vector<std::string>& shader_texts);
    bool enabled() const { return !hooks_.empty(); }

    // src/dst 须同设备、非 mip / 非多重采样；dst 须可作渲染目标。失败回 false（未写 dst）。
    bool Render(ID3D11Texture2D* src, ID3D11Texture2D* dst);

    PlaceboPass(const PlaceboPass&) = delete;
    PlaceboPass& operator=(const PlaceboPass&) = delete;

  private:
    struct Api;
    struct WrappedTex;
    PlaceboPass() = default;
    bool Init(ID3D11Device* device);
    void ClearHooks();
    void ReleaseWrapped(WrappedTex& w);
    bool WrapCached(ID3D11Texture2D* tex, WrappedTex& w);

    std::unique_ptr<Api> api_;
    // pl_* 句柄以 void* 持有：头文件只在 .cc 里包含，避免把 libplacebo 类型泄进 fork 其它翻译单元。
    void* log_ = nullptr;
    void* d3d11_ = nullptr;
    void* gpu_ = nullptr;
    void* renderer_ = nullptr;
    std::vector<const void*> hooks_;
    std::unique_ptr<WrappedTex> src_;
    std::unique_ptr<WrappedTex> dst_;
  };
}
