#!/usr/bin/env bash
# Apple 签名材料的校验 + 写入 GitHub Secrets。
#
# 证书一年一换，描述文件一年一换，密钥可能被撤销重建 —— 每次轮换都要重新走一遍
# 「验证材料自洽 → 写 7~9 个 secret」。手工做这件事的失败模式全是静默的：p12 里
# 装的是 Development 证书而不是 Distribution、描述文件绑的是另一张证书、bundle id
# 拼错一个字母，全都要等 CI 跑到 codesign 才炸，而且报错信息毫无指向性。
# 这个脚本把这些前置条件在本地一次性挡掉。
#
# 用法（只验不写）：
#   tool/apple_signing_secrets.sh --verify-only \
#     --asc-key ~/.appstoreconnect/private_keys/AuthKey_XXXX.p8 \
#     --ios-cert ~/.hibiki-apple-signing/ios_distribution.p12 \
#     --ios-cert-password-file ~/.hibiki-apple-signing/ios_distribution.p12.password \
#     --ios-profile ~/.hibiki-apple-signing/hibiki_appstore.mobileprovision
#
# 用法（验完写入 GitHub）：去掉 --verify-only，补上 --team-id/--asc-key-id/--asc-issuer-id。
# macOS Developer ID 材料用 --macos-cert / --macos-cert-password-file 追加，可与 iOS 分两次跑。
#
# 完整流程见 docs/agent/apple-signing.md。

set -euo pipefail

REPO="hajisensai/hibiki"
VERIFY_ONLY=false
TEAM_ID=""
ASC_KEY_ID=""
ASC_ISSUER_ID=""
ASC_KEY=""
IOS_CERT=""
IOS_CERT_PASSWORD=""
IOS_PROFILE=""
MACOS_CERT=""
MACOS_CERT_PASSWORD=""

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

die() {
  echo "error: $*" >&2
  exit 1
}

fail() {
  echo "  ✗ $*" >&2
  FAILURES=$((FAILURES + 1))
}

ok() {
  echo "  ✓ $*"
}

read_password_file() {
  # 口令走文件而不是命令行参数：命令行参数在 ps / shell history 里对同机其它进程可见。
  [ -f "$1" ] || die "password file not found: $1"
  cat "$1"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --verify-only) VERIFY_ONLY=true; shift ;;
    --team-id) TEAM_ID="$2"; shift 2 ;;
    --asc-key-id) ASC_KEY_ID="$2"; shift 2 ;;
    --asc-issuer-id) ASC_ISSUER_ID="$2"; shift 2 ;;
    --asc-key) ASC_KEY="$2"; shift 2 ;;
    --ios-cert) IOS_CERT="$2"; shift 2 ;;
    --ios-cert-password-file) IOS_CERT_PASSWORD="$(read_password_file "$2")"; shift 2 ;;
    --ios-profile) IOS_PROFILE="$2"; shift 2 ;;
    --macos-cert) MACOS_CERT="$2"; shift 2 ;;
    --macos-cert-password-file) MACOS_CERT_PASSWORD="$(read_password_file "$2")"; shift 2 ;;
    -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# ---- 校验 ------------------------------------------------------------------

if [ -n "$TEAM_ID" ]; then
  echo "team id:"
  if printf '%s' "$TEAM_ID" | grep -Eq '^[A-Z0-9]{10}$'; then
    ok "$TEAM_ID"
  else
    fail "'$TEAM_ID' 不是 10 位大写字母数字的 Team ID（在 developer.apple.com 的 Membership 页）"
  fi
fi

if [ -n "$ASC_ISSUER_ID" ]; then
  echo "asc issuer id:"
  if printf '%s' "$ASC_ISSUER_ID" | grep -Eiq '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'; then
    ok "$ASC_ISSUER_ID"
  else
    fail "'$ASC_ISSUER_ID' 不是 UUID 形态的 Issuer ID"
  fi
fi

if [ -n "$ASC_KEY" ]; then
  echo "asc private key ($ASC_KEY):"
  [ -f "$ASC_KEY" ] || die "asc key not found: $ASC_KEY"
  if openssl pkey -in "$ASC_KEY" -noout 2>/dev/null; then
    ok "可解析的 PKCS#8 私钥"
  else
    fail "无法解析：App Store Connect 下载的是 PEM 文本的 .p8，不要转码或改行尾"
  fi
  if [ -n "$ASC_KEY_ID" ] && ! printf '%s' "$ASC_KEY" | grep -q "$ASC_KEY_ID"; then
    echo "  ! 文件名不含 Key ID $ASC_KEY_ID —— 只是提醒，不影响 CI（CI 按 secret 重新落盘）"
  fi
fi

# p12 里必须同时有「指定类型的证书」和「它的私钥」，且证书没过期。
verify_p12() {
  local label="$1" p12="$2" password="$3" expect_cn="$4"
  echo "$label ($p12):"
  [ -f "$p12" ] || die "p12 not found: $p12"

  local certs
  if ! certs="$(openssl pkcs12 -in "$p12" -passin "pass:$password" -nokeys -clcerts 2>/dev/null)"; then
    fail "口令错误或文件不是 PKCS#12"
    return
  fi
  local subject
  subject="$(printf '%s' "$certs" | openssl x509 -noout -subject 2>/dev/null || true)"
  if printf '%s' "$subject" | grep -q "$expect_cn"; then
    ok "$subject"
  else
    fail "证书不是 '$expect_cn' 类型：$subject"
    echo "     （Development 证书签不了分发包；Developer ID 与 Apple Distribution 也不能互换）"
  fi

  local enddate
  enddate="$(printf '%s' "$certs" | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')"
  if printf '%s' "$certs" | openssl x509 -noout -checkend 0 >/dev/null 2>&1; then
    ok "有效期至 $enddate"
    if ! printf '%s' "$certs" | openssl x509 -noout -checkend 2592000 >/dev/null 2>&1; then
      echo "  ! 30 天内到期（${enddate}），先去 Portal 换新证书再写 secret"
    fi
  else
    fail "证书已于 $enddate 过期"
  fi

  if openssl pkcs12 -in "$p12" -passin "pass:$password" -nocerts -noout 2>/dev/null; then
    ok "私钥在包内"
  else
    fail "p12 里没有私钥 —— 只导出证书是签不了名的，导出时要选证书下面挂的那把密钥"
  fi

  if printf '%s' "$(openssl pkcs12 -in "$p12" -passin "pass:$password" -nokeys -cacerts 2>/dev/null)" \
      | grep -q 'Worldwide Developer Relations'; then
    ok "带 WWDR 中间证书（证书链自足）"
  else
    echo "  ! 不含 WWDR 中间证书。runner 上通常预装了，但打进 p12 更稳"
  fi
}

if [ -n "$IOS_CERT" ]; then
  verify_p12 "ios distribution p12" "$IOS_CERT" "$IOS_CERT_PASSWORD" "Apple Distribution"
fi

if [ -n "$MACOS_CERT" ]; then
  verify_p12 "macos developer id p12" "$MACOS_CERT" "$MACOS_CERT_PASSWORD" "Developer ID Application"
fi

if [ -n "$IOS_PROFILE" ]; then
  echo "ios provisioning profile ($IOS_PROFILE):"
  [ -f "$IOS_PROFILE" ] || die "profile not found: $IOS_PROFILE"
  PROFILE_PLIST="$(mktemp -t hibiki-profile)"
  trap 'rm -f "$PROFILE_PLIST"' EXIT
  if ! security cms -D -i "$IOS_PROFILE" > "$PROFILE_PLIST" 2>/dev/null; then
    fail "不是 CMS 签名的 .mobileprovision"
  else
    PROFILE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$PROFILE_PLIST")"
    APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$PROFILE_PLIST")"
    PROFILE_BUNDLE_ID="${APP_ID#*.}"
    ok "name = $PROFILE_NAME"

    EXPECTED_BUNDLE_ID="$(sed -n 's/.*PRODUCT_BUNDLE_IDENTIFIER = \(.*\);/\1/p' \
      "$REPO_ROOT/hibiki/ios/Runner.xcodeproj/project.pbxproj" | grep -v RunnerTests | head -n 1)"
    if [ "$PROFILE_BUNDLE_ID" = "$EXPECTED_BUNDLE_ID" ]; then
      ok "bundle id = ${PROFILE_BUNDLE_ID}（与 Runner.xcodeproj 一致）"
    else
      fail "描述文件绑的是 '$PROFILE_BUNDLE_ID'，Runner 构建的是 '$EXPECTED_BUNDLE_ID'"
      echo "     （通配符描述文件不能用于 App Store 分发）"
    fi

    # App Store 描述文件不含 ProvisionedDevices；有这个键说明拿错成 ad-hoc/development。
    if /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$PROFILE_PLIST" >/dev/null 2>&1; then
      fail "含 ProvisionedDevices —— 这是 development/ad-hoc 描述文件，不是 App Store 的"
    else
      ok "无 ProvisionedDevices（App Store 类型）"
    fi

    EXPIRY="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$PROFILE_PLIST")"
    ok "有效期至 $EXPIRY"

    # 描述文件里嵌着它授权的证书列表；CI 用的 p12 必须在其中，否则 codesign 过了
    # 而 App Store 校验会拒。
    if [ -n "$IOS_CERT" ]; then
      CERT_DER="$(mktemp -t hibiki-cert)"
      openssl pkcs12 -in "$IOS_CERT" -passin "pass:$IOS_CERT_PASSWORD" -nokeys -clcerts 2>/dev/null \
        | openssl x509 -outform DER -out "$CERT_DER" 2>/dev/null || true
      CERT_FP="$(openssl x509 -inform DER -in "$CERT_DER" -noout -fingerprint -sha1 2>/dev/null \
        | sed 's/.*=//' | tr -d ':')"
      MATCHED=false
      INDEX=0
      while /usr/libexec/PlistBuddy -c "Print :DeveloperCertificates:$INDEX" "$PROFILE_PLIST" >/dev/null 2>&1; do
        EMBEDDED="$(mktemp -t hibiki-embedded)"
        /usr/libexec/PlistBuddy -c "Print :DeveloperCertificates:$INDEX" "$PROFILE_PLIST" > /dev/null
        plutil -extract "DeveloperCertificates.$INDEX" raw -o - "$PROFILE_PLIST" 2>/dev/null \
          | base64 --decode > "$EMBEDDED" 2>/dev/null || true
        EMBEDDED_FP="$(openssl x509 -inform DER -in "$EMBEDDED" -noout -fingerprint -sha1 2>/dev/null \
          | sed 's/.*=//' | tr -d ':')"
        rm -f "$EMBEDDED"
        if [ -n "$EMBEDDED_FP" ] && [ "$EMBEDDED_FP" = "$CERT_FP" ]; then
          MATCHED=true
          break
        fi
        INDEX=$((INDEX + 1))
      done
      rm -f "$CERT_DER"
      if [ "$MATCHED" = true ]; then
        ok "描述文件授权了这张分发证书"
      else
        fail "描述文件里没有这张分发证书 —— 描述文件和 p12 不是一对，去 Portal 重新生成描述文件并勾选这张证书"
      fi
    fi
  fi
fi

if [ "$FAILURES" -gt 0 ]; then
  echo ""
  echo "APPLE SIGNING VERDICT: FAILED - $FAILURES 项校验未通过，未写入任何 secret"
  exit 1
fi

echo ""
echo "APPLE SIGNING VERDICT: PASSED - 所有提供的材料自洽"

if [ "$VERIFY_ONLY" = true ]; then
  exit 0
fi

# ---- 写入 GitHub Secrets ----------------------------------------------------

command -v gh >/dev/null 2>&1 || die "gh CLI 不在 PATH 上"

set_secret() {
  printf '%s' "$2" | gh secret set "$1" -R "$REPO"
  echo "  set $1"
}

echo ""
echo "writing secrets to $REPO:"
[ -n "$TEAM_ID" ] && set_secret APPLE_TEAM_ID "$TEAM_ID"
[ -n "$ASC_KEY_ID" ] && set_secret APPSTORE_API_KEY_ID "$ASC_KEY_ID"
[ -n "$ASC_ISSUER_ID" ] && set_secret APPSTORE_API_ISSUER_ID "$ASC_ISSUER_ID"
if [ -n "$ASC_KEY" ]; then
  gh secret set APPSTORE_API_PRIVATE_KEY -R "$REPO" < "$ASC_KEY"
  echo "  set APPSTORE_API_PRIVATE_KEY"
fi
if [ -n "$IOS_CERT" ]; then
  set_secret IOS_DIST_CERT_P12_BASE64 "$(base64 -i "$IOS_CERT" | tr -d '\n')"
  set_secret IOS_DIST_CERT_P12_PASSWORD "$IOS_CERT_PASSWORD"
fi
if [ -n "$IOS_PROFILE" ]; then
  set_secret IOS_PROVISIONING_PROFILE_BASE64 "$(base64 -i "$IOS_PROFILE" | tr -d '\n')"
fi
if [ -n "$MACOS_CERT" ]; then
  set_secret MACOS_DEVELOPER_ID_P12_BASE64 "$(base64 -i "$MACOS_CERT" | tr -d '\n')"
  set_secret MACOS_DEVELOPER_ID_P12_PASSWORD "$MACOS_CERT_PASSWORD"
fi

echo ""
echo "完成。下一步见 docs/agent/apple-signing.md 的「发一版 TestFlight」。"
