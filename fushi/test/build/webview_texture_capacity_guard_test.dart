import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-3913 源码守卫：Windows WebView 的共享目标纹理与 WGC 帧池按容量分配。
///
/// 背景：每换一次交给 Flutter 的共享纹理句柄，引擎（ANGLE 打开的共享资源）就留下
/// 一份显存不归还；每重建一次 WGC 帧池，系统侧也留下一份帧池缓冲。旧实现两者都
/// 「尺寸一变就重建」，于是 WebView 每改一次尺寸显存固定上涨、永不回收（4K 200%
/// 歌词模式涨到 7 GB）。修复让两者只在超出容量时才重建。
///
/// 为什么落在源码守卫这一层：native 侧（C++ / WGC / D3D11）不在任何 Dart 测试的
/// 编译面上，本仓也没有 Windows 原生单测框架；`packages/flutter_inappwebview_windows`
/// 的包测试（含容量策略单测 `test/texture_capacity_test.dart`）被 CI 的包测试循环
/// 当作 vendored fork 跳过。这里钉住「回到逐尺寸重建」会必然删掉的那几处结构，
/// 显存数字本身的回归只能真机按 docs/bugs/BUG-3913 的采样法复测。
final Directory _repoRoot = Directory.current.parent;

String _read(String relative) => File(
  '${_repoRoot.path}/$relative',
).readAsStringSync().replaceAll('\r\n', '\n');

String _functionBody(String source, String signature) {
  final int start = source.indexOf(signature);
  expect(start, isNonNegative, reason: 'missing function: $signature');
  final int open = source.indexOf('{', start);
  int depth = 0;
  for (int i = open; i < source.length; i++) {
    final String c = source[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return source.substring(open, i + 1);
    }
  }
  fail('unbalanced braces in $signature');
}

const String _pkg = 'packages/flutter_inappwebview_windows';

void main() {
  final String bridge = _read(
    '$_pkg/windows/custom_platform_view/texture_bridge.cc',
  );
  final String gpu = _read(
    '$_pkg/windows/custom_platform_view/texture_bridge_gpu.cc',
  );
  final String dart = _read(
    '$_pkg/lib/src/in_app_webview/custom_platform_view.dart',
  );

  test('WGC 帧池按容量创建，放得下就不重建', () {
    final String create = _functionBody(
      bridge,
      'bool TextureBridge::CreateAndStartFramePoolLocked()',
    );
    expect(
      create,
      contains('FramePoolSizeFor('),
      reason: '帧池尺寸必须取「捕获源与容量逐维取大」，不能贴身取捕获源尺寸',
    );
    final String recreate = _functionBody(
      bridge,
      'bool TextureBridge::RecreateFramePoolLocked()',
    );
    expect(recreate, contains('wanted.Width <= lifetime->size.Width'));
    expect(recreate, contains('wanted.Height <= lifetime->size.Height'));
    expect(
      recreate,
      isNot(contains('current_size.Width == lifetime->size.Width')),
      reason: '「尺寸完全相等才跳过」就是每次改尺寸都重建帧池的旧判据',
    );
    expect(
      bridge,
      contains('get_ContentSize('),
      reason: '帧池比内容大时只有 ContentSize 说明左上角哪一块是有效内容',
    );
  });

  test('共享目标纹理按容量分配，可见内容拷进左上角', () {
    final String process = _functionBody(
      gpu,
      'void TextureBridgeGpu::ProcessFrame(',
    );
    expect(process, contains('SelectSurfaceSize('));
    expect(
      process,
      isNot(contains('CopyResource(')),
      reason: 'CopyResource 要求两张纹理等大 = 共享纹理贴身分配',
    );
    final String select = _functionBody(
      gpu,
      'Size TextureBridgeGpu::SelectSurfaceSize(',
    );
    expect(select, contains('capacity_'));
    final String copy = _functionBody(
      gpu,
      'void TextureBridgeGpu::CopyIntoSurface(',
    );
    expect(copy, contains('CopySubresourceRegion('));
    expect(
      copy,
      contains('ClearRenderTargetView('),
      reason: '容量里内容以外必须清成透明，否则露出残影 / 未初始化显存',
    );
    final String descriptor = _functionBody(
      gpu,
      'TextureBridgeGpu::GetSurfaceDescriptor(',
    );
    expect(
      descriptor,
      isNot(contains('output_size_ = {')),
      reason: '引擎请求尺寸现在是容量盒子，不能再拿来改写可见输出尺寸',
    );
  });

  test('帧池按捕获倍率下的容量分配（着色器路径不按设备倍率超配 4 倍）', () {
    final String poolSize = _functionBody(
      bridge,
      'TextureBridge::FramePoolSizeFor(',
    );
    expect(
      poolSize,
      contains('capture_scale_ratio_'),
      reason: '容量是设备倍率的物理像素，捕获源按捕获倍率栅格化；着色器开时捕获倍率减半',
    );
    expect(poolSize, contains('std::ceil('));
    final String setOutput = _functionBody(
      gpu,
      'void TextureBridgeGpu::SetOutputSize(',
    );
    expect(
      setOutput,
      contains('capture_scale_ratio_ = capture_scale_factor / scale_factor;'),
    );
    final String setShaders = _functionBody(
      gpu,
      'bool TextureBridgeGpu::SetShaders(',
    );
    expect(setShaders, contains('capture_scale_ratio_ ='));
  });

  test('销毁：引擎确认注销前纹理回调落点不释放，注销完成后 Flush 插件设备', () {
    final String cpv = _read(
      '$_pkg/windows/custom_platform_view/custom_platform_view.cc',
    );
    final String dtor = _functionBody(
      cpv,
      'CustomPlatformView::~CustomPlatformView()',
    );
    expect(
      dtor,
      isNot(contains('UnregisterTexture(texture_id_, nullptr)')),
      reason: '无完成回调就随即释放 flutter_texture_ = 栅格线程迟到的纹理回调落在已释放内存上',
    );
    final int detach = dtor.indexOf('texture_endpoint_->bridge = nullptr;');
    final int stop = dtor.indexOf('texture_bridge_->Stop();');
    final int unregister = dtor.indexOf('UnregisterTexture(texture_id_,');
    expect(detach, isNonNegative);
    expect(stop, greaterThan(detach), reason: '先摘桥再停桥，回调不再进入桥');
    expect(unregister, greaterThan(stop));
    final String completion = dtor.substring(unregister);
    expect(completion, contains('retired_texture'));
    expect(
      completion,
      contains('device_context->Flush();'),
      reason: 'D3D11 延迟销毁：不 Flush，释放掉的共享纹理 / 帧池缓冲要等别的 WebView 来帧才归还',
    );
    expect(
      cpv,
      contains('endpoint->descriptor = *descriptor;'),
      reason: '引擎在锁外读描述符，必须指向落点自己的存储而不是桥的成员',
    );
  });

  test('首份纹理容量贴身分配，只在扩容时取整 / 增长', () {
    final String capacity = _read(
      '$_pkg/lib/src/in_app_webview/texture_capacity.dart',
    );
    final String next = _functionBody(capacity, 'int _nextDimension(');
    expect(
      next,
      contains('if (current <= 0) return needed;'),
      reason: '每新建一个 WebView 那一份显存不全数归还，首份取整会把它放大约 18%',
    );
  });

  test('Dart 侧下发容量，并把 Texture 摆成容量尺寸后裁剪', () {
    final String setSize = _functionBody(dart, 'Future<void> _setSize(');
    expect(setSize, contains('nextTextureCapacity('));
    expect(setSize, contains('capacity.width.toDouble()'));
    expect(setSize, contains('capacity.height.toDouble()'));
    final String layout = _functionBody(dart, 'Widget _buildTextureLayout(');
    expect(layout, contains('ClipRect('));
    expect(layout, contains('OverflowBox('));
    expect(layout, contains('Alignment.topLeft'));
    expect(
      dart,
      contains('builder: _buildTextureLayout'),
      reason: 'Texture 必须经容量布局包裹，否则引擎把整张容量纹理压进 widget 盒子',
    );
  });
}
