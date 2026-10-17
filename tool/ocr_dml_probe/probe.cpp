// BUG-2050 定性探针：本机 ORT 1.22.0 (DirectML build) 上，int8 RT-DETR-v2
// 检测器到底能不能建出 DML 会话。
//
// 严格复刻 app 的 DML 设置（third_party/flutter_onnxruntime/windows/src/
// dml_provider.cc）：ORT_SEQUENTIAL + DisableMemPattern +
// OrtDmlApi::SessionOptionsAppendExecutionProvider_DML(device_id=0)。
//
// CPU 会话复刻 flutter_onnxruntime_plugin.cpp 的 createSession：只设
// IntraOpNumThreads（app 在 Windows 上传 planOcrAcceleration 的
// min(核数, 2)），图优化级别 / 内存 arena / 执行模式全用 ORT 默认值
// （ORT_ENABLE_ALL、arena 开、sequential），所以这里也一个都不设。
// --threads 同样作用于 DML 会话：app 不分 EP 一律传 intraOpNumThreads。
//
// 分三段，互不推断：
//   ① GetAvailableProviders()  -> DML 编译进来了吗（我的修复第 1 层依据）
//   ② D3D12CreateDevice        -> 这台机器此刻建得出 D3D12 设备吗（环境）
//   ③ Session(DML) / Session(CPU) -> 真建会话 + 真跑一次 + 计时（模型）
//
// 用法：
//   probe.exe <model.onnx>                       旧行为（DML 与 CPU 各 3 次稳态）
//   probe.exe <model.onnx> [选项]
//     --shape name=1,3,H,W   覆盖某个输入的形状；同名重复给多次 = 多个形状，
//                            每个形状先各跑一次「首次推理」，稳态循环按
//                            S1,S2,S1,S2… 轮换（暴露 DML 按形状重编译的代价）
//     --threads N            IntraOpNumThreads（不给 = ORT 默认）
//     --runs N               稳态次数（默认 3；多形状时是总次数）
//     --block                多形状时稳态按块跑（S1×n, S2×n…）而不是轮换
//     --free-dim name=V      AddFreeDimensionOverrideByName（命名自由维钉死）
//     --session-per-shape    每个 --shape 各建一个会话（分桶方案的暖机总价）
//     --dml-only / --cpu-only

#define NOMINMAX
#include <d3d12.h>
#include <dxgi1_4.h>
#include <windows.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <map>
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
  // DML device_id=0 就是 DXGI 枚举的第 0 块适配器；打出来，免得量的是虚拟显卡。
  IDXGIFactory1* factory = nullptr;
  if (SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
    IDXGIAdapter1* adapter = nullptr;
    for (UINT i = 0; factory->EnumAdapters1(i, &adapter) != DXGI_ERROR_NOT_FOUND;
         i++) {
      DXGI_ADAPTER_DESC1 desc{};
      adapter->GetDesc1(&desc);
      printf("  DXGI adapter %u: %ls  (VRAM %llu MB)%s\n", i, desc.Description,
             (unsigned long long)(desc.DedicatedVideoMemory >> 20),
             (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) ? " [software]" : "");
      adapter->Release();
    }
    factory->Release();
  }
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

struct ProbeConfig {
  // 输入名 -> 一个或多个形状（多个 = 轮换）。
  std::map<std::string, std::vector<std::vector<int64_t>>> shapes;
  int threads = 0;  // 0 = 不设
  int runs = 3;
  bool runDml = true;
  bool runCpu = true;
  bool block = false;
  bool perShapeSession = false;
  // 命名自由维固定（app 插件的 freeDimensionOverrides 同一个 C API）。
  std::vector<std::pair<std::string, int64_t>> freeDims;
  bool legacy = true;  // 没给任何新参数 = 与旧版输出一致
};

struct ShapeStats {
  std::string label;
  double firstRunMs = 0;
  std::vector<double> steady;
};

struct SessionOutcome {
  bool ok = false;
  double createMs = 0;
  double firstRunMs = 0;
  double steadyMs = 0;  // 第 0 个形状的 best（旧口径）
  std::vector<ShapeStats> perShape;
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

static std::string ShapeLabel(const std::vector<int64_t>& s) {
  std::string out = "[";
  for (size_t d = 0; d < s.size(); d++) {
    if (d) out += ",";
    out += std::to_string((long long)s[d]);
  }
  return out + "]";
}

static double Median(std::vector<double> v) {
  if (v.empty()) return 0;
  std::sort(v.begin(), v.end());
  size_t n = v.size();
  return n % 2 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2;
}

static SessionOutcome TrySession(Ort::Env& env, const wchar_t* modelPath,
                                 bool useDml, const ProbeConfig& cfg) {
  SessionOutcome out;
  auto tStart = Clock::now();
  try {
    Ort::SessionOptions opts;
    if (cfg.threads > 0) opts.SetIntraOpNumThreads(cfg.threads);
    for (auto& fd : cfg.freeDims)
      Ort::ThrowOnError(Ort::GetApi().AddFreeDimensionOverrideByName(
          opts, fd.first.c_str(), fd.second));
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

    // ---- 组输入（按 session 元数据，不猜；--shape 覆盖）----
    Ort::AllocatorWithDefaultOptions alloc;
    size_t nIn = session.GetInputCount();
    std::vector<std::string> inNames;
    std::vector<std::vector<int64_t>> declShapes;
    std::vector<ONNXTensorElementDataType> inTypes;
    for (size_t i = 0; i < nIn; i++) {
      auto n = session.GetInputNameAllocated(i, alloc);
      inNames.push_back(n.get());
      auto info = session.GetInputTypeInfo(i).GetTensorTypeAndShapeInfo();
      declShapes.push_back(info.GetShape());
      inTypes.push_back(info.GetElementType());
      if (!cfg.legacy) {
        auto syms = info.GetSymbolicDimensions();
        printf("     input %s symbolic dims:", inNames.back().c_str());
        for (auto* s : syms) printf(" '%s'", s ? s : "");
        printf("\n");
      }
    }

    // 形状组数 = 各输入给的形状数的最大值（短的循环复用）。
    size_t nVariants = 1;
    for (auto& kv : cfg.shapes) nVariants = std::max(nVariants, kv.second.size());
    std::vector<std::vector<std::vector<int64_t>>> variants(nVariants);
    for (size_t v = 0; v < nVariants; v++) {
      for (size_t i = 0; i < nIn; i++) {
        std::vector<int64_t> shape = declShapes[i];
        auto it = cfg.shapes.find(inNames[i]);
        if (it != cfg.shapes.end()) {
          shape = it->second[v % it->second.size()];
        } else {
          for (auto& d : shape) if (d < 0) d = 1;  // 动态维按 1，batch 就是 1
          // RT-DETR: images 的空间维若是动态，按 640 填。
          if (inNames[i] == "images" || inNames[i] == "pixel_values") {
            if (shape.size() == 4) { shape[2] = 640; shape[3] = 640; }
          }
        }
        variants[v].push_back(shape);
      }
    }

    std::vector<std::string> outNames;
    for (size_t i = 0; i < session.GetOutputCount(); i++) {
      auto n = session.GetOutputNameAllocated(i, alloc);
      outNames.push_back(n.get());
    }

    printf("     declared inputs:");
    for (size_t i = 0; i < nIn; i++)
      printf(" %s%st%d", inNames[i].c_str(), ShapeLabel(declShapes[i]).c_str(),
             (int)inTypes[i]);
    printf("\n     outputs:");
    for (auto& o : outNames) printf(" %s", o.c_str());
    printf("\n");

    auto memInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    // 每组形状一套缓冲与张量。
    std::vector<std::vector<std::vector<float>>> fBufs(nVariants);
    std::vector<std::vector<std::vector<int64_t>>> iBufs(nVariants);
    std::vector<std::vector<Ort::Value>> inputs(nVariants);
    for (size_t v = 0; v < nVariants; v++) {
      fBufs[v].resize(nIn);
      iBufs[v].resize(nIn);
      std::string label;
      for (size_t i = 0; i < nIn; i++) {
        auto& shp = variants[v][i];
        size_t n = 1;
        for (auto d : shp) n *= (size_t)d;
        if (inTypes[i] == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64) {
          iBufs[v][i].assign(n, 640);
          inputs[v].push_back(Ort::Value::CreateTensor<int64_t>(
              memInfo, iBufs[v][i].data(), n, shp.data(), shp.size()));
        } else {
          fBufs[v][i].assign(n, 0.5f);
          inputs[v].push_back(Ort::Value::CreateTensor<float>(
              memInfo, fBufs[v][i].data(), n, shp.data(), shp.size()));
        }
        if (i) label += " ";
        label += inNames[i] + ShapeLabel(shp);
      }
      ShapeStats st;
      st.label = label;
      out.perShape.push_back(st);
    }

    std::vector<const char*> inPtr, outPtr;
    for (auto& s : inNames) inPtr.push_back(s.c_str());
    for (auto& s : outNames) outPtr.push_back(s.c_str());

    auto runOnce = [&](size_t v) {
      auto t = Clock::now();
      auto r = session.Run(Ort::RunOptions{nullptr}, inPtr.data(),
                           inputs[v].data(), inPtr.size(), outPtr.data(),
                           outPtr.size());
      return MsSince(t);
    };

    // 每个形状各自的「首次推理」（DML 上含该形状的图编译）。
    for (size_t v = 0; v < nVariants; v++) out.perShape[v].firstRunMs = runOnce(v);
    out.firstRunMs = out.perShape[0].firstRunMs;

    for (int k = 0; k < cfg.runs; k++) {
      // 轮换：S1,S2,S1,S2…；--block：S1×n,S2×n…（区分「形状切换就重编译」与
      // 「只有某个形状走快路径」）。
      size_t v = cfg.block ? std::min(nVariants - 1,
                                      (size_t)k * nVariants / (size_t)cfg.runs)
                           : (size_t)k % nVariants;
      out.perShape[v].steady.push_back(runOnce(v));
    }
    auto& s0 = out.perShape[0].steady;
    out.steadyMs = s0.empty() ? 0 : *std::min_element(s0.begin(), s0.end());
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

static void Report(const char* tag, const SessionOutcome& o, bool legacy) {
  if (!o.ok) {
    printf("  %s: FAILED after %.1fms  <-- 这就是白付的代价\n", tag, o.createMs);
    printf("     ortErrorCode = %s\n", o.errorCode.c_str());
    printf("     message      = %s\n", o.error.c_str());
    return;
  }
  if (legacy) {
    printf("  %s: OK  create=%.1fms  firstRun=%.1fms  steady(best)=%.1fms\n",
           tag, o.createMs, o.firstRunMs, o.steadyMs);
    return;
  }
  printf("  %s: OK  create=%.1fms\n", tag, o.createMs);
  for (auto& s : o.perShape) {
    double best = s.steady.empty()
                      ? 0
                      : *std::min_element(s.steady.begin(), s.steady.end());
    double mx = s.steady.empty()
                    ? 0
                    : *std::max_element(s.steady.begin(), s.steady.end());
    printf("     %-28s first=%8.1fms  steady n=%zu best=%7.2f median=%7.2f max=%7.2f ms\n",
           s.label.c_str(), s.firstRunMs, s.steady.size(), best,
           Median(s.steady), mx);
  }
  // 机器可读的一行，便于汇总。
  printf("RESULT %s create=%.1f", tag, o.createMs);
  for (auto& s : o.perShape)
    printf(" | %s first=%.2f med=%.2f", s.label.c_str(), s.firstRunMs,
           Median(s.steady));
  printf("\n");
}

static bool ParseShapeArg(const std::wstring& arg, ProbeConfig& cfg) {
  // name=1,3,H,W
  size_t eq = arg.find(L'=');
  if (eq == std::wstring::npos) return false;
  std::string name;  // 输入名都是 ASCII
  for (size_t i = 0; i < eq; i++) name.push_back(static_cast<char>(arg[i]));
  std::vector<int64_t> dims;
  std::wstring rest = arg.substr(eq + 1);
  size_t pos = 0;
  while (pos <= rest.size()) {
    size_t comma = rest.find(L',', pos);
    std::wstring tok = rest.substr(pos, comma == std::wstring::npos
                                            ? std::wstring::npos
                                            : comma - pos);
    if (tok.empty()) return false;
    long long d = _wtoi64(tok.c_str());
    if (d <= 0) return false;
    dims.push_back(d);
    if (comma == std::wstring::npos) break;
    pos = comma + 1;
  }
  cfg.shapes[name].push_back(dims);
  return true;
}

int wmain(int argc, wchar_t** argv) {
  if (argc < 2) {
    printf("usage: probe.exe <model.onnx> [--shape name=1,3,H,W]... "
           "[--threads N] [--runs N] [--block] [--free-dim name=V]... "
           "[--session-per-shape] "
           "[--dml-only|--cpu-only]\n");
    return 2;
  }
  ProbeConfig cfg;
  for (int i = 2; i < argc; i++) {
    std::wstring a = argv[i];
    cfg.legacy = false;
    if (a == L"--shape" && i + 1 < argc) {
      if (!ParseShapeArg(argv[++i], cfg)) {
        printf("bad --shape: %ls\n", argv[i]);
        return 2;
      }
    } else if (a == L"--threads" && i + 1 < argc) {
      cfg.threads = _wtoi(argv[++i]);
    } else if (a == L"--runs" && i + 1 < argc) {
      cfg.runs = _wtoi(argv[++i]);
    } else if (a == L"--block") {
      cfg.block = true;
    } else if (a == L"--session-per-shape") {
      cfg.perShapeSession = true;
    } else if (a == L"--free-dim" && i + 1 < argc) {
      std::wstring v = argv[++i];
      size_t eq = v.find(L'=');
      if (eq == std::wstring::npos) {
        printf("bad --free-dim: %ls\n", v.c_str());
        return 2;
      }
      std::string n;
      for (size_t k = 0; k < eq; k++) n.push_back(static_cast<char>(v[k]));
      cfg.freeDims.push_back({n, _wtoi64(v.c_str() + eq + 1)});
    } else if (a == L"--dml-only") {
      cfg.runCpu = false;
    } else if (a == L"--cpu-only") {
      cfg.runDml = false;
    } else {
      printf("unknown arg: %ls\n", a.c_str());
      return 2;
    }
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

  if (cfg.legacy) {
    printf("\n=== [3] 真建会话（int8 RT-DETR-v2 检测器）\n");
  } else {
    printf("\n=== [3] 真建会话  threads=%d runs=%d\n", cfg.threads, cfg.runs);
  }
  if (cfg.perShapeSession) {
    // 每个形状一个独立会话（同一进程、同一 Env）：分桶方案的真实代价。
    double total = 0;
    for (auto& kv : cfg.shapes) {
      for (auto& shp : kv.second) {
        ProbeConfig one = cfg;
        one.shapes.clear();
        one.shapes[kv.first].push_back(shp);
        for (int ep = 0; ep < 2; ep++) {
          bool useDml = ep == 0;
          if ((useDml && !cfg.runDml) || (!useDml && !cfg.runCpu)) continue;
          SessionOutcome o = TrySession(env, argv[1], useDml, one);
          Report(useDml ? "DML" : "CPU", o, false);
          if (o.ok) total += o.createMs + o.firstRunMs;
        }
      }
    }
    printf("RESULT per-shape-session warmup total (create+first) = %.1fms\n",
           total);
    return 0;
  }
  SessionOutcome dml, cpu;
  if (cfg.runDml) {
    printf("  --- DirectML ---\n");
    dml = TrySession(env, argv[1], true, cfg);
    Report("DML", dml, cfg.legacy);
  }
  if (cfg.runCpu) {
    printf("  --- CPU ---\n");
    cpu = TrySession(env, argv[1], false, cfg);
    Report("CPU", cpu, cfg.legacy);
  }

  if (!(cfg.runDml && cfg.runCpu)) return 0;
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
