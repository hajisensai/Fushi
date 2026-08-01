#!/usr/bin/env bash
# 共享代理解析：给 tool/ 下需要联网（gh / git）的 bash 脚本用。
#
# 背景：本机 fake-ip DNS 下 gh 直连 api.github.com 会解析到 198.18.x.x 假 IP 必超时，
# 所以这些脚本历史上各自写死了一个本机代理地址作为回退。写死的问题是
# 本机端口进了公开仓库、换机器指向一个不存在的端口，且两份拷贝会各自漂移。
#
# 解析顺序（与 tool/bootstrap.ps1 建立的先例一致）：
#   1) 调用方已设的 HTTPS_PROXY / HTTP_PROXY / ALL_PROXY —— 最高优先级，绝不覆盖
#   2) HIBIKI_BOOTSTRAP_PROXY —— 专用变量，只影响本仓工具链
#   3) <主 checkout>/tool/bootstrap.local.env 里的 HIBIKI_BOOTSTRAP_PROXY / HTTPS_PROXY
#      （KEY=VALUE，已 gitignore，本机私有，一次配置长期生效）
#   4) 都没有 —— **照常跑**，不设代理、不报错。CI 与直连环境走这条。
#
# 用法：在脚本开头 `source "$(dirname "${BASH_SOURCE[0]}")/proxy_env.sh"`，
# 它只导出 HTTPS_PROXY / HTTP_PROXY，不产生任何输出（除非 HIBIKI_PROXY_VERBOSE=1）。

hibiki_resolve_proxy() {
  # 1) 调用方已设
  if [ -n "${HTTPS_PROXY:-}" ] || [ -n "${HTTP_PROXY:-}" ] || [ -n "${ALL_PROXY:-}" ]; then
    _hibiki_proxy="${HTTPS_PROXY:-${HTTP_PROXY:-$ALL_PROXY}}"
    _hibiki_proxy_source="调用方环境变量"
    return 0
  fi
  # 2) 专用变量
  if [ -n "${HIBIKI_BOOTSTRAP_PROXY:-}" ]; then
    _hibiki_proxy="$HIBIKI_BOOTSTRAP_PROXY"
    _hibiki_proxy_source="HIBIKI_BOOTSTRAP_PROXY"
    return 0
  fi
  # 3) 本机配置文件（放主 checkout，所有 worktree 共用）
  local root cfg line key val
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  root="$(cygpath -m "$root" 2>/dev/null || echo "$root")"
  # git worktree 的主 checkout：common dir 的上一级
  local common
  common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -n "$common" ]; then
    common="$(cygpath -m "$common" 2>/dev/null || echo "$common")"
    cfg="$(dirname "$common")/tool/bootstrap.local.env"
  else
    cfg="$root/tool/bootstrap.local.env"
  fi
  if [ -f "$cfg" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in \#*|"") continue;; esac
      key="${line%%=*}"; val="${line#*=}"
      key="$(printf '%s' "$key" | tr -d '[:space:]')"
      val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')"
      case "$key" in
        HIBIKI_BOOTSTRAP_PROXY|HTTPS_PROXY)
          if [ -n "$val" ]; then
            _hibiki_proxy="$val"
            _hibiki_proxy_source="$cfg"
            return 0
          fi
          ;;
      esac
    done < "$cfg"
  fi
  # 4) 没有就没有——照常跑
  _hibiki_proxy=""
  _hibiki_proxy_source=""
  return 0
}

hibiki_resolve_proxy
if [ -n "${_hibiki_proxy:-}" ]; then
  export HTTPS_PROXY="$_hibiki_proxy"
  export HTTP_PROXY="${HTTP_PROXY:-$_hibiki_proxy}"
  [ "${HIBIKI_PROXY_VERBOSE:-}" = "1" ] && echo "代理: $_hibiki_proxy (来源: $_hibiki_proxy_source)" >&2
fi
unset _hibiki_proxy _hibiki_proxy_source
