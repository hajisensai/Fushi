// BUG-2050 定性探针：本机 ORT 1.22.0 (DirectML build) 上，int8 RT-DETR-v2
// 检测器到底能不能建出 DML 会话。
//
// 严格复刻 app 的 DML 设置（third_party/flutter_onnxruntime/windows/src/
// dml_provider.cc）：ORT_SEQUENTIAL + DisableMemPattern +
// OrtDmlApi::SessionOptionsAppendExecutionProvider_DML(device_id=0)。
//
// 分三段，互不推断：
//   ① GetAvailableProviders()  -> DML 编译进来了吗（我的修复第 1 层依据）
//   ② D3D12CreateDevice        -> 这台机器此刻建得出 D3D12 设备吗（环境）
//   ③ Session(DML) / Session(CPU) -> 真建会话 + 真跑一次 + 计时（模型）

#include <d3d12.h>
#include <dxgi1_4.h>
#include <windows.h>

#include <chrono>
#include <cstdio>
#include <string>
#include <vector>

#include <dml_provider_factory.h>
#include <onnxruntime_cxx_api.h>

using Clock = std::chrono::steady_clock;

static double MsSince(Clock::time_point t0) {
  return std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
}

static void ProbeD3D12() {
  printf("\n=== [2] D3D12 device creation (环境闸门)\n");
  ID3D12Device* dev = nullptr;
  HRESULT hr = D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_11_0,
                                 IID_PPV_ARGS(&dev));
  if (SUCCEEDED(hr)) {
    printf("  HARDWARE D3D12CreateDevice: OK\n");
    dev->Release();
  } else {
    printf("  HARDWARE D3D12CreateDevice: FAILED hr=0x%08lX\n",
           static_cast<unsigned long>(hr));
    if (hr == E_OUTOFMEMORY) {
      printf("  -> E_OUTOFMEMORY：本机 WDDM 资源被打满（GPU 客户端过多）。\n");
      printf("     这是环境状态，不是模型/代码问题，会自行波动。\n");
    }
  }
}

struct SessionOutcome {
  bool ok = false;
  double createMs = 0;
  double firstRunMs = 0;
  double steadyMs = 0;
  std::string error;
  std::string errorCode;
};

static const char* OrtErrCodeName(OrtErrorCode c) {
  switch (c) {
    case ORT_OK: return "ORT_OK";
    case ORT_FAIL: return "ORT_FAIL";
    case ORT_INVALID_ARGUMENT: return "ORT_INVALID_ARGUMENT";
    case ORT_NO_SUCHFILE: return "ORT_NO_SUCHFILE";
    case ORT_NO_MODEL: return "ORT_NO_MODEL";
    case ORT_ENGINE_ERROR: return "ORT_ENGINE_ERROR";
    case ORT_RUNTIME_EXCEPTION: return "ORT_RUNTIME_EXCEPTION";
    case ORT_INVALID_PROTOBUF: return "ORT_INVALID_PROTOBUF";
    case ORT_MODEL_LOADED: return "ORT_MODEL_LOADED";
    case ORT_NOT_IMPLEMENTED: return "ORT_NOT_IMPLEMENTED";
    case ORT_INVALID_GRAPH: return "ORT_INVALID_GRAPH";
    case ORT_EP_FAIL: return "ORT_EP_FAIL";
    default: return "ORT_UNKNOWN";
  }
}

static SessionOutcome TrySession(Ort::Env& env, const wchar_t* modelPath,
                                 bool useDml, int runs) {
  SessionOutcome out;
  auto tStart = Clock::now();
  try {
    Ort::SessionOptions opts;
    if (useDml) {
      // 与 dml_provider.cc 完全一致。
      opts.SetExecutionMode(ExecutionMode::ORT_SEQUENTIAL);
      opts.DisableMemPattern();
      const OrtDmlApi* dmlApi = nullptr;
      Ort::ThrowOnError(Ort::GetApi().GetExecutionProviderApi(
          "DML", ORT_API_VERSION, reinterpret_cast<const void**>(&dmlApi)));
      if (dmlApi == nullptr) {
        out.error = "ONNX Runtime returned no DirectML provider API";
        return out;
      }
      Ort::ThrowOnError(
          dmlApi->SessionOptionsAppendExecutionProvider_DML(opts, 0));
    }

    auto t0 = Clock::now();
    Ort::Session session(env, modelPath, opts);
    out.createMs = MsSince(t0);

    // ---- 组输入（按 session 元数据，不猜）----
    Ort::AllocatorWithDefaultOptions alloc;
    size_t nIn = session.GetInputCount();
    std::vector<std::string> inNames;
    std::vector<std::vector<int64_t>> inShapes;
    std::vector<ONNXTensorElementDataType> inTypes;
    for (size_t i = 0; i < nIn; i++) {
      auto n = session.GetInputNameAllocated(i, alloc);
      inNames.push_back(n.get());
      auto info = session.GetInputTypeInfo(i).GetTensorTypeAndShapeInfo();
      auto shape = info.GetShape();
      for (auto& d : shape) if (d < 0) d = 1;  // 动态维按 1，batch 就是 1
      // RT-DETR: images 的空间维若是动态，按 640 填。
      if (inNames.back() == "images" || inNames.back() == "pixel_values") {
        if (shape.size() == 4) { shape[2] = 640; shape[3] = 640; }
      }
      inShapes.push_back(shape);
      inTypes.push_back(info.GetElementType());
    }

    std::vector<std::string> outNames;
    for (size_t i = 0; i < session.GetOutputCount(); i++) {
      auto n = session.GetOutputNameAllocated(i, alloc);
      outNames.push_back(n.get());
    }

    printf("     inputs:");
    for (size_t i = 0; i < nIn; i++) {
      printf(" %s[", inNames[i].c_str());
      for (size_t d = 0; d < inShapes[i].size(); d++)
        printf("%s%lld", d ? "," : "", (long long)inShapes[i][d]);
      printf("]t%d", (int)inTypes[i]);
    }
    printf("\n     outputs:");
    for (auto& o : outNames) printf(" %s", o.c_str());
    printf("\n");

    auto memInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    std::vector<std::vector<float>> fBufs(nIn);
    std::vector<std::vector<int64_t>> iBufs(nIn);
    std::vector<Ort::Value> inputs;
    for (size_t i = 0; i < nIn; i++) {
      size_t n = 1;
      for (auto d : inShapes[i]) n *= (size_t)d;
      if (inTypes[i] == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64) {
        iBufs[i].assign(n, 640);
        inputs.push_back(Ort::Value::CreateTensor<int64_t>(
            memInfo, iBufs[i].data(), n, inShapes[i].data(), inShapes[i].size()));
      } else {
        fBufs[i].assign(n, 0.5f);
        inputs.push_back(Ort::Value::CreateTensor<float>(
            memInfo, fBufs[i].data(), n, inShapes[i].data(), inShapes[i].size()));
      }
    }

    std::vector<const char*> inPtr, outPtr;
    for (auto& s : inNames) inPtr.push_back(s.c_str());
    for (auto& s : outNames) outPtr.push_back(s.c_str());

    auto t1 = Clock::now();
    auto r = session.Run(Ort::RunOptions{nullptr}, inPtr.data(), inputs.data(),
                         inPtr.size(), outPtr.data(), outPtr.size());
    out.firstRunMs = MsSince(t1);

    double best = 1e18;
    for (int k = 0; k < runs; k++) {
      auto t2 = Clock::now();
      auto rr = session.Run(Ort::RunOptions{nullptr}, inPtr.data(),
                            inputs.data(), inPtr.size(), outPtr.data(),
                            outPtr.size());
      double ms = MsSince(t2);
      if (ms < best) best = ms;
    }
    out.steadyMs = best;
    out.ok = true;
  } catch (const Ort::Exception& e) {
    out.error = e.what();
    out.errorCode = OrtErrCodeName(e.GetOrtErrorCode());
    out.createMs = MsSince(tStart);  // 白付的代价
  } catch (const std::exception& e) {
    out.error = e.what();
    out.errorCode = "std::exception";
    out.createMs = MsSince(tStart);
  }
  return out;
}

static void Report(const char* tag, const SessionOutcome& o) {
  if (o.ok) {
    printf("  %s: OK  create=%.1fms  firstRun=%.1fms  steady(best)=%.1fms\n",
           tag, o.createMs, o.firstRunMs, o.steadyMs);
  } else {
    printf("  %s: FAILED after %.1fms  <-- 这就是白付的代价\n", tag, o.createMs);
    printf("     ortErrorCode = %s\n", o.errorCode.c_str());
    printf("     message      = %s\n", o.error.c_str());
  }
}

int wmain(int argc, wchar_t** argv) {
  if (argc < 2) {
    printf("usage: probe.exe <model.onnx>\n");
    return 2;
  }
  printf("ONNX Runtime build: %s\n", Ort::GetVersionString().c_str());

  printf("\n=== [1] GetAvailableProviders() (我的修复第 1 层依据)\n");
  auto provs = Ort::GetAvailableProviders();
  bool hasDml = false;
  for (auto& p : provs) {
    printf("  - %s\n", p.c_str());
    if (p == "DmlExecutionProvider") hasDml = true;
  }
  printf("  => DmlExecutionProvider present: %s\n", hasDml ? "YES" : "NO");

  ProbeD3D12();

  Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "bug2050probe");

  printf("\n=== [3] 真建会话（int8 RT-DETR-v2 检测器）\n");
  printf("  --- DirectML ---\n");
  SessionOutcome dml = TrySession(env, argv[1], true, 3);
  Report("DML", dml);

  printf("  --- CPU ---\n");
  SessionOutcome cpu = TrySession(env, argv[1], false, 3);
  Report("CPU", cpu);

  printf("\n=== 结论\n");
  if (dml.ok && cpu.ok) {
    printf("  DML 建得起来。steady DML=%.1fms CPU=%.1fms -> DML/CPU = %.2fx\n",
           dml.steadyMs, cpu.steadyMs, cpu.steadyMs / dml.steadyMs);
  } else if (!dml.ok && cpu.ok) {
    printf("  DML 建不起来，CPU 可以。DML 失败码=%s\n", dml.errorCode.c_str());
  } else {
    printf("  两边都有问题，见上。\n");
  }
  return 0;
}
