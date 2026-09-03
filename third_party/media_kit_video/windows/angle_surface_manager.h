// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#ifndef ANGLE_SURFACE_MANAGER_H_
#define ANGLE_SURFACE_MANAGER_H_

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <EGL/eglplatform.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

#include <Windows.h>

#include <d3d.h>
#include <d3d11.h>
#include <wrl.h>

#include "utils.h"

#include <cstdint>
#include <functional>

// |ANGLESurfaceManager| provides an abstraction around ANGLE to easily draw
// OpenGL ES 2.0 content & read as D3D 11 texture using shared |HANDLE|.
// * |Draw|: Takes callback where OpenGL ES 2.0 calls can be made for rendering.
// * |Read|: Copies the drawn content to D3D 11 texture & makes it available to
//           the shared |handle| for access.

// A large part of implementation is inspired from Flutter.
// https://github.com/flutter/engine/blob/master/shell/platform/windows/angle_surface_manager.h

class ANGLESurfaceManager {
 public:
  const int32_t width() const { return width_; }
  const int32_t height() const { return height_; }
  const HANDLE handle() const { return handle_; }

  ANGLESurfaceManager(int32_t width, int32_t height);

  ~ANGLESurfaceManager();

  void SetSize(int32_t width, int32_t height);

  void Draw(std::function<void()> callback);

  void Read();

  void MakeCurrent(bool value);

  // Whether ANGLE renders on the Direct3D 11 device this class created (see
  // |shared_d3d_11_device_|). When false, libmpv can only reach ANGLE's own
  // hidden device and therefore falls back from `d3d11va` to `d3d11va-copy`,
  // reading every decoded frame back through system memory.
  static bool uses_shared_d3d11_device() {
    return shared_display_uses_our_device_;
  }

 private:
  void SwapBuffers();

  void Create();

  void CleanUp(bool release_context);

  bool CreateD3DTexture();

  bool CreateEGLDisplay();

  bool CreateAndBindEGLSurface();

  // Creates (once per process) the Direct3D 11 device every |ANGLESurfaceManager|
  // draws into. See |ANGLESurfaceManager::shared_d3d_11_device_|.
  static bool EnsureSharedD3D11Device();

  // Creates (once per process) the |EGLDisplay|. Prefers an ANGLE display that
  // runs on |shared_d3d_11_device_| so libmpv's `d3d11-egl` hardware decoding
  // interop can adopt the very same device; falls back to letting ANGLE create
  // its own hidden device.
  static bool EnsureSharedEGLDisplay();

  // Destroys the process wide device & display. Only called by the last living
  // |ANGLESurfaceManager|.
  static void ReleaseSharedResources();

  // BUG-1657: tears the device-backed display down and rebuilds the surface on
  // ANGLE's own display, so a failure downstream of the interop display costs
  // the zero-copy interop instead of costing hardware rendering (and with it,
  // silently, every `glsl-shaders` / `scale` filter). Returns false when the
  // retry is not applicable or also failed.
  bool RetryOnUpstreamEGLDisplay();

  int32_t width_ = 1;
  int32_t height_ = 1;
  HANDLE internal_handle_ = nullptr;
  HANDLE handle_ = nullptr;

  // Sync |Draw| & |Read| calls.
  HANDLE mutex_ = nullptr;
  // D3D 11. Non-owning aliases of |shared_d3d_11_device_| &
  // |shared_d3d_11_device_context_|; never |Release|d per instance.
  ID3D11Device* d3d_11_device_ = nullptr;
  ID3D11DeviceContext* d3d_11_device_context_ = nullptr;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> internal_d3d_11_texture_2D_;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> d3d_11_texture_2D_;
  // ANGLE
  EGLSurface surface_ = EGL_NO_SURFACE;
  EGLDisplay display_ = EGL_NO_DISPLAY;
  EGLContext context_ = nullptr;
  EGLConfig config_ = nullptr;

  static constexpr EGLint kEGLConfigurationAttributes[] = {
      EGL_RED_SIZE,   8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE,    8,
      EGL_ALPHA_SIZE, 8, EGL_DEPTH_SIZE, 8, EGL_STENCIL_SIZE, 8,
      EGL_NONE,
  };
  static constexpr EGLint kEGLContextAttributes[] = {
      EGL_CONTEXT_CLIENT_VERSION,
      2,
      EGL_NONE,
  };
  static constexpr EGLint kD3D11DisplayAttributes[] = {
      EGL_PLATFORM_ANGLE_TYPE_ANGLE,
      EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE,
      EGL_PLATFORM_ANGLE_ENABLE_AUTOMATIC_TRIM_ANGLE,
      EGL_TRUE,
      EGL_NONE,
  };
  static constexpr EGLint kD3D11_9_3DisplayAttributes[] = {
      EGL_PLATFORM_ANGLE_TYPE_ANGLE,
      EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE,
      EGL_PLATFORM_ANGLE_MAX_VERSION_MAJOR_ANGLE,
      9,
      EGL_PLATFORM_ANGLE_MAX_VERSION_MINOR_ANGLE,
      3,
      EGL_PLATFORM_ANGLE_ENABLE_AUTOMATIC_TRIM_ANGLE,
      EGL_TRUE,
      EGL_NONE,
  };
  static constexpr EGLint kD3D9DisplayAttributes[] = {
      EGL_PLATFORM_ANGLE_TYPE_ANGLE,
      EGL_PLATFORM_ANGLE_TYPE_D3D9_ANGLE,
      EGL_PLATFORM_ANGLE_DEVICE_TYPE_ANGLE,
      EGL_PLATFORM_ANGLE_DEVICE_TYPE_HARDWARE_ANGLE,
      EGL_NONE,
  };
  static constexpr EGLint kWrapDisplayAttributes[] = {
      EGL_PLATFORM_ANGLE_TYPE_ANGLE,
      EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE,
      EGL_PLATFORM_ANGLE_ENABLE_AUTOMATIC_TRIM_ANGLE,
      EGL_TRUE,
      EGL_NONE,
  };

  // Number of active instances of ANGLESurfaceManager.
  static int32_t instance_count_;

  // HIBIKI FORK: process wide Direct3D 11 device.
  //
  // Upstream created one |ID3D11Device| per |ANGLESurfaceManager| *and* let
  // ANGLE create yet another, hidden one (|EGL_DEFAULT_DISPLAY|). libmpv's
  // `d3d11-egl` hardware decoding interop resolves its decoding device through
  // `EGL_DEVICE_EXT` -> `EGL_D3D11_DEVICE_ANGLE`, i.e. it can only ever see
  // ANGLE's hidden device: one nobody created with
  // |D3D11_CREATE_DEVICE_VIDEO_SUPPORT| and nobody marked thread safe. Sharing
  // a single device that we create with the right flags and then handing it to
  // ANGLE puts decoder, renderer & presentation on one device.
  static ID3D11Device* shared_d3d_11_device_;
  static ID3D11DeviceContext* shared_d3d_11_device_context_;
  // ANGLE handle wrapping |shared_d3d_11_device_|; |EGL_NO_DEVICE_EXT| when the
  // interop path was not taken.
  static EGLDeviceEXT shared_egl_device_;
  // The one |EGLDisplay| every instance renders on.
  static EGLDisplay shared_display_;
  // Whether ANGLE actually runs on |shared_d3d_11_device_|.
  static bool shared_display_uses_our_device_;
  // Set once the device-backed display has proven unusable (BUG-1657), so it is
  // not rebuilt for this or any later instance.
  static bool shared_interop_display_disabled_;
};

#endif  // ANGLE_SURFACE_MANAGER_H_
