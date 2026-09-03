#include "placebo_pass.h"

#include <cstring>
#include <iostream>

// 只取结构体布局与函数签名；符号全部经 GetProcAddress 解析，绝不直接引用（无导入库）。
#include <libplacebo/d3d11.h>
#include <libplacebo/log.h>
#include <libplacebo/renderer.h>
#include <libplacebo/shaders/custom.h>

namespace flutter_inappwebview_plugin
{
  namespace
  {
    constexpr const wchar_t* kPlaceboDll = L"libplacebo-360.dll";

    void PlaceboLog(void*, enum pl_log_level level, const char* msg)
    {
      if (level <= PL_LOG_WARN) {
        std::cerr << "[libplacebo] " << msg << std::endl;
      }
    }
  }

  struct PlaceboPass::Api {
    HMODULE dll = nullptr;
    decltype(&pl_log_create) log_create = nullptr;
    decltype(&pl_log_destroy) log_destroy = nullptr;
    decltype(&pl_d3d11_create) d3d11_create = nullptr;
    decltype(&pl_d3d11_destroy) d3d11_destroy = nullptr;
    decltype(&pl_d3d11_wrap) d3d11_wrap = nullptr;
    decltype(&pl_tex_destroy) tex_destroy = nullptr;
    decltype(&pl_renderer_create) renderer_create = nullptr;
    decltype(&pl_renderer_destroy) renderer_destroy = nullptr;
    decltype(&pl_render_image) render_image = nullptr;
    decltype(&pl_mpv_user_shader_parse) shader_parse = nullptr;
    decltype(&pl_mpv_user_shader_destroy) shader_destroy = nullptr;
    const struct pl_render_params* render_fast_params = nullptr;
    const struct pl_color_repr* color_repr_rgb = nullptr;
    const struct pl_color_space* color_space_srgb = nullptr;

    template <typename T>
    bool Load(T& out, const char* name)
    {
      out = reinterpret_cast<T>(GetProcAddress(dll, name));
      if (!out) {
        std::cerr << "[libplacebo] missing export: " << name << std::endl;
      }
      return out != nullptr;
    }

    ~Api()
    {
      if (dll) {
        FreeLibrary(dll);
      }
    }
  };

  struct PlaceboPass::WrappedTex {
    ID3D11Texture2D* source = nullptr;  // 身份比较用，不持引用
    pl_tex tex = nullptr;
  };

  std::unique_ptr<PlaceboPass> PlaceboPass::Create(ID3D11Device* device)
  {
    if (!device) {
      return nullptr;
    }
    std::unique_ptr<PlaceboPass> pass(new PlaceboPass());
    if (!pass->Init(device)) {
      return nullptr;
    }
    return pass;
  }

  bool PlaceboPass::Init(ID3D11Device* device)
  {
    api_ = std::make_unique<Api>();
    // 随包 DLL 落在 exe 同级，默认搜索序即可命中；缺失 = fail-open。
    api_->dll = LoadLibraryW(kPlaceboDll);
    if (!api_->dll) {
      std::cerr << "[libplacebo] " << "libplacebo-360.dll not found; super-resolution disabled" << std::endl;
      return false;
    }
    // pl_log_create 是带 API 版本后缀的宏（pl_log_create_360）：字符串化后即真实导出名。
#define PL_STR2(x) #x
#define PL_STR(x) PL_STR2(x)
    bool ok = api_->Load(api_->log_create, PL_STR(pl_log_create))
      && api_->Load(api_->log_destroy, "pl_log_destroy")
      && api_->Load(api_->d3d11_create, "pl_d3d11_create")
      && api_->Load(api_->d3d11_destroy, "pl_d3d11_destroy")
      && api_->Load(api_->d3d11_wrap, "pl_d3d11_wrap")
      && api_->Load(api_->tex_destroy, "pl_tex_destroy")
      && api_->Load(api_->renderer_create, "pl_renderer_create")
      && api_->Load(api_->renderer_destroy, "pl_renderer_destroy")
      && api_->Load(api_->render_image, "pl_render_image")
      && api_->Load(api_->shader_parse, "pl_mpv_user_shader_parse")
      && api_->Load(api_->shader_destroy, "pl_mpv_user_shader_destroy")
      && api_->Load(api_->render_fast_params, "pl_render_fast_params")
      && api_->Load(api_->color_repr_rgb, "pl_color_repr_rgb")
      && api_->Load(api_->color_space_srgb, "pl_color_space_srgb");
#undef PL_STR
#undef PL_STR2
    if (!ok) {
      return false;
    }

    struct pl_log_params log_params = {};
    log_params.log_cb = &PlaceboLog;
    log_params.log_level = PL_LOG_WARN;
    pl_log log = api_->log_create(PL_API_VER, &log_params);
    if (!log) {
      return false;
    }
    log_ = const_cast<void*>(static_cast<const void*>(log));

    struct pl_d3d11_params d3d_params = {};
    d3d_params.device = device;  // libplacebo 自己 AddRef
    d3d_params.allow_software = true;
    pl_d3d11 d3d11 = api_->d3d11_create(log, &d3d_params);
    if (!d3d11) {
      std::cerr << "[libplacebo] pl_d3d11_create failed on the shared device" << std::endl;
      return false;
    }
    d3d11_ = const_cast<void*>(static_cast<const void*>(d3d11));
    gpu_ = const_cast<void*>(static_cast<const void*>(d3d11->gpu));

    pl_renderer rr = api_->renderer_create(log, d3d11->gpu);
    if (!rr) {
      return false;
    }
    renderer_ = static_cast<void*>(rr);
    src_ = std::make_unique<WrappedTex>();
    dst_ = std::make_unique<WrappedTex>();
    return true;
  }

  PlaceboPass::~PlaceboPass()
  {
    if (!api_) {
      return;
    }
    ClearHooks();
    if (src_) ReleaseWrapped(*src_);
    if (dst_) ReleaseWrapped(*dst_);
    if (renderer_ && api_->renderer_destroy) {
      pl_renderer rr = static_cast<pl_renderer>(renderer_);
      api_->renderer_destroy(&rr);
      renderer_ = nullptr;
    }
    if (d3d11_ && api_->d3d11_destroy) {
      pl_d3d11 d = static_cast<pl_d3d11>(d3d11_);
      api_->d3d11_destroy(&d);
      d3d11_ = nullptr;
      gpu_ = nullptr;
    }
    if (log_ && api_->log_destroy) {
      pl_log log = static_cast<pl_log>(log_);
      api_->log_destroy(&log);
      log_ = nullptr;
    }
  }

  void PlaceboPass::ClearHooks()
  {
    for (const void* h : hooks_) {
      const struct pl_hook* hook = static_cast<const struct pl_hook*>(h);
      api_->shader_destroy(&hook);
    }
    hooks_.clear();
  }

  bool PlaceboPass::SetShaders(const std::vector<std::string>& shader_texts)
  {
    ClearHooks();
    if (!gpu_) {
      return false;
    }
    pl_gpu gpu = static_cast<pl_gpu>(gpu_);
    bool all_ok = true;
    for (const std::string& text : shader_texts) {
      const struct pl_hook* hook = api_->shader_parse(gpu, text.data(), text.size());
      if (!hook) {
        std::cerr << "[libplacebo] user shader failed to parse (" << text.size() << " bytes)" << std::endl;
        all_ok = false;
        continue;
      }
      hooks_.push_back(hook);
    }
    if (!all_ok) {
      // 解析失败必须整链 fail-open；调用方会恢复 full-DPR capture。保留半条链会
      // 让 Dart 收到 false、native 却继续着色，并且源尺寸策略无法判定。
      ClearHooks();
    }
    return all_ok;
  }

  void PlaceboPass::ReleaseWrapped(WrappedTex& w)
  {
    if (w.tex && gpu_) {
      api_->tex_destroy(static_cast<pl_gpu>(gpu_), &w.tex);
    }
    w.tex = nullptr;
    w.source = nullptr;
  }

  bool PlaceboPass::WrapCached(ID3D11Texture2D* tex, WrappedTex& w)
  {
    if (w.tex && w.source == tex) {
      return true;
    }
    ReleaseWrapped(w);
    struct pl_d3d11_wrap_params params = {};
    params.tex = tex;
    w.tex = api_->d3d11_wrap(static_cast<pl_gpu>(gpu_), &params);
    if (!w.tex) {
      std::cerr << "[libplacebo] pl_d3d11_wrap failed" << std::endl;
      return false;
    }
    w.source = tex;
    return true;
  }

  namespace
  {
    void FillFrame(struct pl_frame& f, pl_tex tex, const struct pl_color_repr& repr,
      const struct pl_color_space& color, bool storage_order_mapping)
    {
      std::memset(&f, 0, sizeof(f));
      f.num_planes = 1;
      f.planes[0].texture = tex;
      // 源：component_mapping 按纹理**存储序**给语义通道（renderer.h 的 Y/CbCr-on-BGRA 例子）。
      // WGC 帧是 B8G8R8A8，存储分量 0 是蓝色；libplacebo d3d11 的 bgra8 格式
      // sample_order={2,1,0,3} 正好给出每个存储分量的语义下标（rgba 类格式恒等）。
      // 目标：真机对照（同一帧开/关）实测 wrapped 的 bgra8 渲染目标**不**再按存储序换位——
      // 源/目标都按存储序映射时 R/B 仍对调（两侧互相抵消），只有源按存储序、目标恒等才
      // 得到与直通一致的颜色。这是 libplacebo d3d11 后端对 wrapped BGRA 目标的行为，
      // 不是本文件的猜测；改这里前先用 itest 的 shaded/unshaded 对照截图复核。
      const struct pl_fmt_t* fmt = tex->params.format;
      const int comps = fmt->num_components < 4 ? fmt->num_components : 4;
      f.planes[0].components = comps;
      for (int i = 0; i < 4; i++) {
        if (i >= comps) {
          f.planes[0].component_mapping[i] = -1;
        } else {
          f.planes[0].component_mapping[i] = storage_order_mapping ? fmt->sample_order[i] : i;
        }
      }
      f.repr = repr;
      f.color = color;
      f.crop.x0 = 0;
      f.crop.y0 = 0;
      f.crop.x1 = static_cast<float>(tex->params.w);
      f.crop.y1 = static_cast<float>(tex->params.h);
    }
  }

  bool PlaceboPass::Render(ID3D11Texture2D* src, ID3D11Texture2D* dst)
  {
    if (!renderer_ || !gpu_ || !src || !dst) {
      return false;
    }
    if (!WrapCached(src, *src_) || !WrapCached(dst, *dst_)) {
      return false;
    }
    struct pl_frame image;
    struct pl_frame target;
    FillFrame(image, src_->tex, *api_->color_repr_rgb, *api_->color_space_srgb, true);
    FillFrame(target, dst_->tex, *api_->color_repr_rgb, *api_->color_space_srgb, false);

    // fast 预设（不做高阶缩放/抖动，页面帧本来就是 sRGB 8bit），只挂用户着色器。
    struct pl_render_params params = *api_->render_fast_params;
    params.hooks = hooks_.empty()
      ? nullptr
      : reinterpret_cast<const struct pl_hook* const*>(hooks_.data());
    params.num_hooks = static_cast<int>(hooks_.size());
    return api_->render_image(static_cast<pl_renderer>(renderer_), &image, &target, &params);
  }
}
