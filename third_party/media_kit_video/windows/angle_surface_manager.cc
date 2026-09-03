// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.
#include "angle_surface_manager.h"

#include <iostream>

#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3d11.lib")

#define FAIL(message)                                                 \
  std::cout << "media_kit: ANGLESurfaceManager: Failure: " << message \
            << std::endl;                                             \
  return false

#define CHECK_HRESULT(message) \
  if (FAILED(hr)) {            \
    FAIL(message);             \
  }

int ANGLESurfaceManager::instance_count_ = 0;

ID3D11Device* ANGLESurfaceManager::shared_d3d_11_device_ = nullptr;
ID3D11DeviceContext* ANGLESurfaceManager::shared_d3d_11_device_context_ =
    nullptr;
EGLDeviceEXT ANGLESurfaceManager::shared_egl_device_ = EGL_NO_DEVICE_EXT;
EGLDisplay ANGLESurfaceManager::shared_display_ = EGL_NO_DISPLAY;
bool ANGLESurfaceManager::shared_display_uses_our_device_ = false;
bool ANGLESurfaceManager::shared_interop_display_disabled_ = false;

ANGLESurfaceManager::ANGLESurfaceManager(int32_t width, int32_t height)
    : width_(width), height_(height) {
  mutex_ = ::CreateMutex(NULL, FALSE, NULL);
  Create();
  instance_count_++;
}

ANGLESurfaceManager::~ANGLESurfaceManager() {
  CleanUp(true);
  ::ReleaseMutex(mutex_);
  ::CloseHandle(mutex_);
  instance_count_--;
}

void ANGLESurfaceManager::SetSize(int32_t width, int32_t height) {
  if (width == width_ && height == height_) {
    return;
  }
  width_ = width;
  height_ = height;
  Create();
}

void ANGLESurfaceManager::Draw(std::function<void()> callback) {
  ::WaitForSingleObject(mutex_, INFINITE);
  MakeCurrent(true);
  callback();
  SwapBuffers();
  MakeCurrent(false);
  ::ReleaseMutex(mutex_);
}

void ANGLESurfaceManager::Read() {
  ::WaitForSingleObject(mutex_, INFINITE);
  if (d3d_11_device_context_ != nullptr) {
    d3d_11_device_context_->CopyResource(d3d_11_texture_2D_.Get(),
                                         internal_d3d_11_texture_2D_.Get());
    d3d_11_device_context_->Flush();
  }
  ::ReleaseMutex(mutex_);
}

void ANGLESurfaceManager::MakeCurrent(bool value) {
  if (value) {
    eglMakeCurrent(display_, surface_, surface_, context_);
  } else {
    eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  }
}

void ANGLESurfaceManager::SwapBuffers() {
  glFinish();
}

void ANGLESurfaceManager::Create() {
  CleanUp(false);
  if (!CreateD3DTexture()) {
    throw std::runtime_error("Unable to create Windows Direct3D device.");
    return;
  }
  if (!CreateEGLDisplay()) {
    throw std::runtime_error("Unable to create ANGLE EGL display.");
    return;
  }
  if (!CreateAndBindEGLSurface()) {
    // HIBIKI FORK (BUG-1657): BUG-1644 introduced a *new* display type
    // (EGL_PLATFORM_DEVICE_EXT on our own device). |EnsureSharedEGLDisplay|
    // only falls back to the upstream EGL_DEFAULT_DISPLAY chain when creating
    // that display fails; anything failing *after* it (config, context,
    // pbuffer-from-share-handle) used to land straight in |VideoOutput|'s
    // software renderer. That is a silent, expensive downgrade: the S/W path
    // renders with MPV_RENDER_API_TYPE_SW, which is not vo=gpu, so libmpv's
    // `glsl-shaders` (Anime4K & friends) and the `scale`/`cscale` filters stop
    // applying entirely -- measured: the very same shader set inlines 2016
    // `conv2d` references into the generated shaders on the GL path and zero on
    // the S/W path. Retry once on the well-trodden upstream display before
    // giving up on hardware rendering.
    if (!RetryOnUpstreamEGLDisplay()) {
      throw std::runtime_error("Unable to create ANGLE EGL surface.");
    }
  }
  if (internal_handle_ == nullptr || handle_ == nullptr) {
    throw std::runtime_error("Unable to retrieve Direct3D shared HANDLE.");
    return;
  }
}

void ANGLESurfaceManager::CleanUp(bool release_context) {
  if (release_context) {
    if (display_ != EGL_NO_DISPLAY && surface_ != EGL_NO_SURFACE) {
      eglReleaseTexImage(display_, surface_, EGL_BACK_BUFFER);
    }
    if (display_ != EGL_NO_DISPLAY && context_ != EGL_NO_CONTEXT) {
      eglDestroyContext(display_, context_);
      context_ = EGL_NO_CONTEXT;
    }
    if (surface_ != EGL_NO_SURFACE) {
      eglDestroySurface(display_, surface_);
      surface_ = EGL_NO_SURFACE;
    }
    // HIBIKI FORK: the |EGLDisplay| & the Direct3D device are process wide now
    // (see |shared_d3d_11_device_|), so only the last instance may tear them
    // down. |d3d_11_device_| / |d3d_11_device_context_| are non-owning aliases
    // and are merely forgotten here; upstream |Release|d them per instance,
    // which would now free the device out from under the surviving instances.
    if (instance_count_ == 1) {
      ReleaseSharedResources();
    }
    display_ = EGL_NO_DISPLAY;
    d3d_11_device_context_ = nullptr;
    d3d_11_device_ = nullptr;
  } else {
    // Clear context & destroy existing |surface_|.
    eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, context_);
    if (display_ != EGL_NO_DISPLAY && surface_ != EGL_NO_SURFACE) {
      eglDestroySurface(display_, surface_);
    }
    surface_ = EGL_NO_SURFACE;
  }
  // Release D3D 11 texture(s).
  if (internal_d3d_11_texture_2D_) {
    internal_d3d_11_texture_2D_->Release();
    internal_d3d_11_texture_2D_ = nullptr;
  }
  if (d3d_11_texture_2D_) {
    d3d_11_texture_2D_->Release();
    d3d_11_texture_2D_ = nullptr;
  }
}

bool ANGLESurfaceManager::EnsureSharedD3D11Device() {
  if (shared_d3d_11_device_ != nullptr) {
    return true;
  }

  // NOTE: Not enabling Feature Level 12. It crashes directly on Windows 7.
  const D3D_FEATURE_LEVEL feature_levels[] = {
      D3D_FEATURE_LEVEL_11_0,
      D3D_FEATURE_LEVEL_10_1,
      D3D_FEATURE_LEVEL_10_0,
      D3D_FEATURE_LEVEL_9_3,
  };

  IDXGIAdapter* adapter = nullptr;
  D3D_DRIVER_TYPE driver_type = D3D_DRIVER_TYPE_UNKNOWN;

  // NOTE: Automatically selecting adapter on Windows 10 RTM or greater.
  if (Utils::IsWindows10RTMOrGreater()) {
    adapter = NULL;
    driver_type = D3D_DRIVER_TYPE_HARDWARE;
  } else {
    IDXGIFactory* dxgi = nullptr;
    ::CreateDXGIFactory(__uuidof(IDXGIFactory), (void**)&dxgi);
    // As far as my experience goes, this is the safest approach. Passing NULL
    // (so-called default) seems to cause issues on Windows 7 or maybe some
    // older graphics drivers. First adapter is the default.
    // D3D_DRIVER_TYPE_UNKNOWN| must be passed with manual adapter selection.
    dxgi->EnumAdapters(0, &adapter);
    dxgi->Release();
  }

  // HIBIKI FORK: |D3D11_CREATE_DEVICE_VIDEO_SUPPORT| is what makes this device
  // usable as libmpv's hardware decoding device: FFmpeg's D3D11VA device init
  // does a QueryInterface for |ID3D11VideoDevice|, which drivers may refuse on
  // a device created without the flag (measured: E_NOINTERFACE on WARP).
  // |D3D11_CREATE_DEVICE_BGRA_SUPPORT| is what ANGLE wants. Both are dropped
  // one by one if the driver rejects them, so a machine that cannot do either
  // still gets exactly the device upstream would have created.
  const UINT device_flag_candidates[] = {
      D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
      D3D11_CREATE_DEVICE_BGRA_SUPPORT,
      0,
  };
  HRESULT hr = E_FAIL;
  for (UINT device_flags : device_flag_candidates) {
    hr = ::D3D11CreateDevice(adapter, driver_type, 0, device_flags,
                             feature_levels,
                             ARRAYSIZE(feature_levels),
                             D3D11_SDK_VERSION, &shared_d3d_11_device_, 0,
                             &shared_d3d_11_device_context_);
    if (SUCCEEDED(hr)) {
      std::cout << "media_kit: ANGLESurfaceManager: Direct3D device flags: 0x"
                << std::hex << device_flags << std::dec << std::endl;
      break;
    }
  }
  if (adapter != nullptr) {
    adapter->Release();
  }
  CHECK_HRESULT("D3D11CreateDevice");

  // The device is touched by libmpv's decoder threads, media_kit's render
  // thread pool & Flutter's raster thread at the same time. libmpv turns this
  // on itself once its interop adopts the device, but ANGLE and the Flutter
  // texture already share it before that happens.
  Microsoft::WRL::ComPtr<ID3D10Multithread> multithread;
  if (SUCCEEDED(shared_d3d_11_device_->QueryInterface(
          __uuidof(ID3D10Multithread), (void**)&multithread)) &&
      multithread != nullptr) {
    multithread->SetMultithreadProtected(TRUE);
  }

  Microsoft::WRL::ComPtr<IDXGIDevice> dxgi_device = nullptr;
  auto dxgi_device_success = shared_d3d_11_device_->QueryInterface(
      __uuidof(IDXGIDevice), (void**)&dxgi_device);
  if (SUCCEEDED(dxgi_device_success) && dxgi_device != nullptr) {
    dxgi_device->SetGPUThreadPriority(5);  // Must be in interval [-7, 7].
  }

  auto level = shared_d3d_11_device_->GetFeatureLevel();
  std::cout << "media_kit: ANGLESurfaceManager: Direct3D Feature Level: "
            << (((unsigned)level) >> 12) << "_"
            << ((((unsigned)level) >> 8) & 0xf) << std::endl;
  return true;
}

bool ANGLESurfaceManager::CreateD3DTexture() {
  if (!EnsureSharedD3D11Device()) {
    return false;
  }
  d3d_11_device_ = shared_d3d_11_device_;
  d3d_11_device_context_ = shared_d3d_11_device_context_;

  auto d3d11_texture2D_desc = D3D11_TEXTURE2D_DESC{0};
  d3d11_texture2D_desc.Width = width_;
  d3d11_texture2D_desc.Height = height_;
  d3d11_texture2D_desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  d3d11_texture2D_desc.MipLevels = 1;
  d3d11_texture2D_desc.ArraySize = 1;
  d3d11_texture2D_desc.SampleDesc.Count = 1;
  d3d11_texture2D_desc.SampleDesc.Quality = 0;
  d3d11_texture2D_desc.Usage = D3D11_USAGE_DEFAULT;
  d3d11_texture2D_desc.BindFlags =
      D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  d3d11_texture2D_desc.CPUAccessFlags = 0;
  d3d11_texture2D_desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;

  // The general idea is to create two textures, one that is used to |Draw|
  // using ANGLE & another one that is used for |Read| the rendered content
  // using |handle|.
  // The internal texture is copied to the public texture once a frame is
  // requested using |ID3D11DeviceContext::CopyResource|. This prevents any kind
  // of synchronization issues.

  // Internal.
  auto hr = d3d_11_device_->CreateTexture2D(&d3d11_texture2D_desc, nullptr,
                                            &internal_d3d_11_texture_2D_);
  CHECK_HRESULT("ID3D11Device::CreateTexture2D");
  auto resource = Microsoft::WRL::ComPtr<IDXGIResource>{};
  hr = internal_d3d_11_texture_2D_.As(&resource);
  CHECK_HRESULT("ID3D11Texture2D::As");
  // Retrieve the shared |HANDLE| for interop.
  hr = resource->GetSharedHandle(&internal_handle_);
  CHECK_HRESULT("IDXGIResource::GetSharedHandle");
  internal_d3d_11_texture_2D_->AddRef();

  // External.
  hr = d3d_11_device_->CreateTexture2D(&d3d11_texture2D_desc, nullptr,
                                       &d3d_11_texture_2D_);
  CHECK_HRESULT("ID3D11Device::CreateTexture2D");
  hr = d3d_11_texture_2D_.As(&resource);
  CHECK_HRESULT("ID3D11Texture2D::As");
  // Retrieve the shared |HANDLE| for interop.
  hr = resource->GetSharedHandle(&handle_);
  CHECK_HRESULT("IDXGIResource::GetSharedHandle");
  d3d_11_texture_2D_->AddRef();

  return true;
}

bool ANGLESurfaceManager::EnsureSharedEGLDisplay() {
  if (shared_display_ != EGL_NO_DISPLAY) {
    return true;
  }

  auto eglGetPlatformDisplayEXT =
      reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
          eglGetProcAddress("eglGetPlatformDisplayEXT"));
  if (!eglGetPlatformDisplayEXT) {
    FAIL("eglGetProcAddress");
  }

  // HIBIKI FORK: preferred path - run ANGLE on the device we created instead of
  // letting it create a hidden one. libmpv's `d3d11-egl` interop reads its
  // decoding device back out of the display
  // (`EGL_DEVICE_EXT` -> `EGL_D3D11_DEVICE_ANGLE`), so this is the only way to
  // decide which device decodes: with ANGLE's hidden device, `d3d11va` falls
  // back to `d3d11va-copy`, i.e. every frame is read back to system memory and
  // re-uploaded. This mirrors what mpv's own `--gpu-context=angle` does.
  auto eglCreateDeviceANGLE = reinterpret_cast<PFNEGLCREATEDEVICEANGLEPROC>(
      eglGetProcAddress("eglCreateDeviceANGLE"));
  if (shared_d3d_11_device_ != nullptr && eglCreateDeviceANGLE != nullptr &&
      !shared_interop_display_disabled_) {
    shared_egl_device_ = eglCreateDeviceANGLE(EGL_D3D11_DEVICE_ANGLE,
                                              shared_d3d_11_device_, nullptr);
    if (shared_egl_device_ != EGL_NO_DEVICE_EXT) {
      auto display = eglGetPlatformDisplayEXT(EGL_PLATFORM_DEVICE_EXT,
                                              shared_egl_device_, nullptr);
      if (display != EGL_NO_DISPLAY && eglInitialize(display, 0, 0)) {
        shared_display_ = display;
        shared_display_uses_our_device_ = true;
        std::cout << "media_kit: ANGLESurfaceManager: ANGLE bound to the "
                     "shared Direct3D 11 device (libmpv d3d11-egl zero-copy "
                     "interop available)."
                  << std::endl;
        return true;
      }
      auto eglReleaseDeviceANGLE =
          reinterpret_cast<PFNEGLRELEASEDEVICEANGLEPROC>(
              eglGetProcAddress("eglReleaseDeviceANGLE"));
      if (eglReleaseDeviceANGLE) {
        eglReleaseDeviceANGLE(shared_egl_device_);
      }
      shared_egl_device_ = EGL_NO_DEVICE_EXT;
    }
    std::cout << "media_kit: ANGLESurfaceManager: Could not bind ANGLE to the "
                 "shared Direct3D 11 device; falling back to ANGLE's own "
                 "device (hardware decoding will copy through system memory)."
              << std::endl;
  }

  shared_display_ = eglGetPlatformDisplayEXT(
      EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, kD3D11DisplayAttributes);
  if (eglInitialize(shared_display_, 0, 0) == EGL_FALSE) {
    shared_display_ =
        eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY,
                                 kD3D11_9_3DisplayAttributes);
    if (eglInitialize(shared_display_, 0, 0) == EGL_FALSE) {
      shared_display_ = eglGetPlatformDisplayEXT(
          EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, kD3D9DisplayAttributes);
      if (eglInitialize(shared_display_, 0, 0) == EGL_FALSE) {
        shared_display_ =
            eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE,
                                     EGL_DEFAULT_DISPLAY, kWrapDisplayAttributes);
        if (eglInitialize(shared_display_, 0, 0) == EGL_FALSE) {
          shared_display_ = EGL_NO_DISPLAY;
          FAIL("eglGetPlatformDisplayEXT");
        }
      }
    }
  }
  return true;
}

void ANGLESurfaceManager::ReleaseSharedResources() {
  if (shared_display_ != EGL_NO_DISPLAY) {
    eglTerminate(shared_display_);
    shared_display_ = EGL_NO_DISPLAY;
  }
  if (shared_egl_device_ != EGL_NO_DEVICE_EXT) {
    auto eglReleaseDeviceANGLE = reinterpret_cast<PFNEGLRELEASEDEVICEANGLEPROC>(
        eglGetProcAddress("eglReleaseDeviceANGLE"));
    if (eglReleaseDeviceANGLE) {
      eglReleaseDeviceANGLE(shared_egl_device_);
    }
    shared_egl_device_ = EGL_NO_DEVICE_EXT;
  }
  shared_display_uses_our_device_ = false;
  if (shared_d3d_11_device_context_ != nullptr) {
    shared_d3d_11_device_context_->Release();
    shared_d3d_11_device_context_ = nullptr;
  }
  if (shared_d3d_11_device_ != nullptr) {
    shared_d3d_11_device_->Release();
    shared_d3d_11_device_ = nullptr;
  }
}

bool ANGLESurfaceManager::RetryOnUpstreamEGLDisplay() {
  // Only meaningful when the device-backed display is what we are on, and only
  // safe for the very first instance: |instance_count_| is bumped after the
  // constructor returns, so 0 means nobody else is rendering on the shared
  // display we are about to terminate.
  if (!shared_display_uses_our_device_ || instance_count_ != 0) {
    return false;
  }
  std::cout << "media_kit: ANGLESurfaceManager: EGL surface creation failed on "
               "the shared Direct3D 11 device; retrying on ANGLE's own display "
               "(hardware rendering kept, zero-copy interop given up)."
            << std::endl;

  // The context/surface belong to the display we are terminating; eglTerminate
  // destroys them, so just forget the handles instead of double-destroying.
  context_ = EGL_NO_CONTEXT;
  surface_ = EGL_NO_SURFACE;
  display_ = EGL_NO_DISPLAY;
  if (shared_display_ != EGL_NO_DISPLAY) {
    eglTerminate(shared_display_);
    shared_display_ = EGL_NO_DISPLAY;
  }
  if (shared_egl_device_ != EGL_NO_DEVICE_EXT) {
    auto eglReleaseDeviceANGLE = reinterpret_cast<PFNEGLRELEASEDEVICEANGLEPROC>(
        eglGetProcAddress("eglReleaseDeviceANGLE"));
    if (eglReleaseDeviceANGLE) {
      eglReleaseDeviceANGLE(shared_egl_device_);
    }
    shared_egl_device_ = EGL_NO_DEVICE_EXT;
  }
  shared_display_uses_our_device_ = false;
  // Make |EnsureSharedEGLDisplay| skip the device-backed attempt from now on,
  // otherwise this instance (and every later one) would rebuild the display
  // that just proved unusable.
  shared_interop_display_disabled_ = true;

  return CreateEGLDisplay() && CreateAndBindEGLSurface();
}

bool ANGLESurfaceManager::CreateEGLDisplay() {
  if (display_ == EGL_NO_DISPLAY) {
    if (!EnsureSharedEGLDisplay()) {
      return false;
    }
    display_ = shared_display_;
  }
  return true;
}

bool ANGLESurfaceManager::CreateAndBindEGLSurface() {
  // Do not create |context_| again, likely due to |Resize|.
  if (context_ == EGL_NO_CONTEXT) {
    // First time from the constructor itself.
    auto count = 0;
    auto result = eglChooseConfig(display_, kEGLConfigurationAttributes,
                                  &config_, 1, &count);
    if (result == EGL_FALSE || count == 0) {
      FAIL("eglChooseConfig");
    }
    context_ = eglCreateContext(display_, config_, EGL_NO_CONTEXT,
                                kEGLContextAttributes);
    if (context_ == EGL_NO_CONTEXT) {
      FAIL("eglCreateContext");
    }
  }
  EGLint buffer_attributes[] = {
      EGL_WIDTH,          width_,         EGL_HEIGHT,         height_,
      EGL_TEXTURE_TARGET, EGL_TEXTURE_2D, EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA,
      EGL_NONE,
  };
  surface_ = eglCreatePbufferFromClientBuffer(
      display_, EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE, internal_handle_,
      config_, buffer_attributes);
  if (surface_ == EGL_NO_SURFACE) {
    FAIL("eglCreatePbufferFromClientBuffer");
  }
  GLuint t;
  glGenTextures(1, &t);
  glBindTexture(GL_TEXTURE_2D, t);
  eglBindTexImage(display_, surface_, EGL_BACK_BUFFER);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  return true;
}
