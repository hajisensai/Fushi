#pragma once

#include <cstdint>
#include <cwchar>
#include <vector>

namespace fushi_voice_hook {

struct ProcessIdentity {
  uint32_t pid = 0;
  uint64_t created_at = 0;
};

// A launch session retains identity and lifetime evidence, not snapshots of PID
// links. An exited relay remains usable only for children born during its life.
class ChildProcessLineage {
 public:
  static constexpr size_t kMaxProcesses = 256;
  static constexpr int kMaxDepth = 16;
  struct Node {
    ProcessIdentity identity;
    uint64_t alive_through = 0;
    uint64_t exited_at = 0;
    int depth = 0;
    uint32_t parent_pid = 0;
  };

  explicit ChildProcessLineage(ProcessIdentity root) {
    if (root.pid != 0 && root.created_at != 0) {
      nodes_.push_back({root, root.created_at, 0, 0});
    }
  }
  const Node* Find(uint32_t pid) const {
    for (const auto& node : nodes_) {
      if (node.identity.pid == pid) return &node;
    }
    return nullptr;
  }
  bool UpdateLifetime(ProcessIdentity identity, uint64_t observed_at,
                      uint64_t exited_at) {
    for (auto& node : nodes_) {
      if (node.identity.pid != identity.pid) continue;
      if (node.identity.created_at != identity.created_at ||
          observed_at < identity.created_at ||
          (exited_at != 0 && (exited_at < identity.created_at ||
                              exited_at > observed_at)) ||
          (node.exited_at != 0 && node.exited_at != exited_at)) return false;
      if (observed_at > node.alive_through) node.alive_through = observed_at;
      node.exited_at = exited_at;
      return true;
    }
    return false;
  }
  bool Observe(ProcessIdentity identity, uint32_t parent_pid) {
    if (identity.pid == 0 || identity.created_at == 0 ||
        identity.pid == parent_pid) return false;
    if (const auto* existing = Find(identity.pid)) {
      return existing->identity.created_at == identity.created_at &&
             existing->depth > 0 && existing->parent_pid == parent_pid;
    }
    const auto* parent = Find(parent_pid);
    if (parent == nullptr || parent->depth >= kMaxDepth ||
        nodes_.size() >= kMaxProcesses ||
        identity.created_at <= parent->identity.created_at ||
        identity.created_at > (parent->exited_at != 0 ? parent->exited_at
                                                     : parent->alive_through)) {
      return false;
    }
    const int depth = parent->depth + 1;
    nodes_.push_back({identity, identity.created_at, 0, depth, parent_pid});
    return true;
  }
  size_t size() const { return nodes_.size(); }

 private:
  std::vector<Node> nodes_;
};

struct ChildProcessCandidate {
  uint32_t pid = 0;
  uint32_t parent_pid = 0;
  const wchar_t* executable_name = nullptr;
  bool has_avcodec = false;
  bool has_avformat = false;
  // 该进程镜像所在目录带引擎数据签名（Siglus 的 Gameexe.dat + Scene.pck 等）。
  // 这是比 ffmpeg 模块更强的「它就是真游戏」证据：ffmpeg 只说明这个进程在解码，
  // 引擎签名说明它就是那台引擎本身。启动器型游戏（AngelBeats 体験版：
  // Start.exe -> StartData/StartMenu.exe -> gamedata/SiglusEngine.exe）里真正的
  // 游戏进程一个 ffmpeg 模块都不加载，只有这条证据认得出它。
  bool has_engine_signature = false;
};

inline bool EqualsAsciiInsensitive(const wchar_t* left, const wchar_t* right) {
  if (left == nullptr || right == nullptr) return false;
  while (*left != 0 && *right != 0) {
    wchar_t a = *left++;
    wchar_t b = *right++;
    if (a >= L'A' && a <= L'Z') a = static_cast<wchar_t>(a - L'A' + L'a');
    if (b >= L'A' && b <= L'Z') b = static_cast<wchar_t>(b - L'A' + L'a');
    if (a != b) return false;
  }
  return *left == 0 && *right == 0;
}

inline int DescendantDepth(uint32_t root_pid, size_t candidate_index,
                           const std::vector<ChildProcessCandidate>& candidates) {
  uint32_t parent = candidates[candidate_index].parent_pid;
  for (int depth = 1; depth <= 16 && parent != 0; ++depth) {
    if (parent == root_pid) return depth;
    bool found = false;
    for (const ChildProcessCandidate& candidate : candidates) {
      if (candidate.pid == parent) {
        parent = candidate.parent_pid;
        found = true;
        break;
      }
    }
    if (!found) return 0;
  }
  return 0;
}

inline int ChildProcessScore(const ChildProcessCandidate& candidate,
                             int depth) {
  if (candidate.pid == 0 || depth <= 0) return -1;
  const bool python =
      EqualsAsciiInsensitive(candidate.executable_name, L"python.exe") ||
      EqualsAsciiInsensitive(candidate.executable_name, L"pythonw.exe");
  if (!candidate.has_avcodec && !candidate.has_avformat && !python &&
      !candidate.has_engine_signature) {
    return -1;
  }
  int score = 100 - depth;
  if (candidate.has_avcodec) score += 300;
  if (candidate.has_avformat) score += 300;
  if (python) score += 250;
  // 压过 avcodec+avformat 全中（600）：解码器进程可能只是个 helper，引擎签名不会。
  if (candidate.has_engine_signature) score += 700;
  return score;
}

inline uint32_t SelectGameChildProcess(
    uint32_t root_pid, const std::vector<ChildProcessCandidate>& candidates) {
  uint32_t best_pid = 0;
  int best_score = 0;
  for (size_t i = 0; i < candidates.size(); ++i) {
    const int score =
        ChildProcessScore(candidates[i], DescendantDepth(root_pid, i, candidates));
    if (score > best_score ||
        (score == best_score && score > 0 && candidates[i].pid < best_pid)) {
      best_score = score;
      best_pid = candidates[i].pid;
    }
  }
  return best_pid;
}

}  // namespace fushi_voice_hook
