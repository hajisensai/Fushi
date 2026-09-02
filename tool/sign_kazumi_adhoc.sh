#!/usr/bin/env bash
set -euo pipefail

readonly KAZUMI_VERSION="2.3.0"
readonly KAZUMI_UNSIGNED_SHA256="f46016bfc1d481cb94a588a8c734d8b18efa68f7ac959f370d189eb1a8776611"
readonly KAZUMI_BUNDLE_ID="app.fushi.kazumi.internal"
readonly ASC_API="https://api.appstoreconnect.apple.com"

required_env=(
  APPLE_TEAM_ID
  APPSTORE_API_KEY_ID
  APPSTORE_API_ISSUER_ID
  APPSTORE_API_PRIVATE_KEY
  IOS_DIST_CERT_P12_BASE64
  IOS_DIST_CERT_P12_PASSWORD
  KAZUMI_DEVICE_1_NAME
  KAZUMI_DEVICE_1_UDID
  KAZUMI_DEVICE_2_NAME
  KAZUMI_DEVICE_2_UDID
  KAZUMI_OUTPUT_DIR
)
for key in "${required_env[@]}"; do
  if [[ -z "${!key:-}" ]]; then
    echo "::error title=Missing signing input::$key is required" >&2
    exit 1
  fi
done

for udid in "$KAZUMI_DEVICE_1_UDID" "$KAZUMI_DEVICE_2_UDID"; do
  if [[ ! "$udid" =~ ^[0-9A-Fa-f-]{24,40}$ ]]; then
    echo "::error title=Invalid device UDID::$udid is not an Apple device UDID" >&2
    exit 1
  fi
done

work_dir="$(mktemp -d "$RUNNER_TEMP/kazumi-adhoc.XXXXXX")"
keychain_path="$RUNNER_TEMP/kazumi-signing.keychain-db"
keychain_password="$(openssl rand -base64 24)"
p12_path="$work_dir/distribution.p12"

cleanup() {
  security delete-keychain "$keychain_path" >/dev/null 2>&1 || true
  rm -rf "$work_dir"
}
trap cleanup EXIT

generate_jwt() {
  ruby <<'RUBY'
require "base64"
require "json"
require "openssl"

encode = ->(value) { Base64.urlsafe_encode64(value, padding: false) }
header = encode.call({ alg: "ES256", kid: ENV.fetch("APPSTORE_API_KEY_ID"), typ: "JWT" }.to_json)
now = Time.now.to_i
payload = encode.call({
  iss: ENV.fetch("APPSTORE_API_ISSUER_ID"),
  iat: now,
  exp: now + 1_100,
  aud: "appstoreconnect-v1"
}.to_json)
input = "#{header}.#{payload}"
key = OpenSSL::PKey.read(ENV.fetch("APPSTORE_API_PRIVATE_KEY"))
der = key.sign(OpenSSL::Digest.new("SHA256"), input)
sequence = OpenSSL::ASN1.decode(der)
raw = sequence.value.map { |integer| integer.value.to_s(2).rjust(32, "\0") }.join
puts "#{input}.#{encode.call(raw)}"
RUBY
}

asc_token="$(generate_jwt)"

api_get() {
  local resource="$1"
  shift
  curl --fail-with-body --silent --show-error --get \
    -H "Authorization: Bearer $asc_token" \
    -H "Content-Type: application/json" \
    "$ASC_API$resource" "$@"
}

api_post() {
  local resource="$1"
  local body="$2"
  curl --fail-with-body --silent --show-error \
    -X POST \
    -H "Authorization: Bearer $asc_token" \
    -H "Content-Type: application/json" \
    --data "$body" \
    "$ASC_API$resource"
}

ensure_device() {
  local name="$1"
  local udid="$2"
  local response device_id status body
  response="$(api_get /v1/devices --data-urlencode "filter[udid]=$udid" --data-urlencode 'limit=1')"
  device_id="$(jq -r '.data[0].id // empty' <<<"$response")"
  if [[ -n "$device_id" ]]; then
    status="$(jq -r '.data[0].attributes.status // empty' <<<"$response")"
    if [[ "$status" != "ENABLED" ]]; then
      echo "::error title=Device disabled::$name ($udid) is registered but not enabled" >&2
      exit 1
    fi
    echo "device already registered: $name ($device_id)" >&2
    printf '%s' "$device_id"
    return
  fi

  body="$(jq -n \
    --arg name "$name" \
    --arg udid "$udid" \
    '{data:{type:"devices",attributes:{name:$name,platform:"IOS",udid:$udid}}}')"
  response="$(api_post /v1/devices "$body")"
  device_id="$(jq -er '.data.id' <<<"$response")"
  echo "registered device: $name ($device_id)" >&2
  printf '%s' "$device_id"
}

ensure_bundle_id() {
  local response bundle_id body
  response="$(api_get /v1/bundleIds \
    --data-urlencode "filter[identifier]=$KAZUMI_BUNDLE_ID" \
    --data-urlencode 'filter[platform]=IOS' \
    --data-urlencode 'limit=1')"
  bundle_id="$(jq -r '.data[0].id // empty' <<<"$response")"
  if [[ -n "$bundle_id" ]]; then
    echo "bundle ID already registered: $KAZUMI_BUNDLE_ID ($bundle_id)" >&2
    printf '%s' "$bundle_id"
    return
  fi

  body="$(jq -n \
    --arg identifier "$KAZUMI_BUNDLE_ID" \
    '{data:{type:"bundleIds",attributes:{identifier:$identifier,name:"Kazumi Internal",platform:"IOS"}}}')"
  response="$(api_post /v1/bundleIds "$body")"
  bundle_id="$(jq -er '.data.id' <<<"$response")"
  echo "registered bundle ID: $KAZUMI_BUNDLE_ID ($bundle_id)" >&2
  printf '%s' "$bundle_id"
}

printf '%s' "$IOS_DIST_CERT_P12_BASE64" | base64 --decode > "$p12_path"
local_serial="$(
  openssl pkcs12 -in "$p12_path" -clcerts -nokeys \
    -passin "pass:$IOS_DIST_CERT_P12_PASSWORD" 2>/dev/null \
    | openssl x509 -noout -serial \
    | sed 's/^serial=//I' \
    | tr '[:lower:]' '[:upper:]'
)"
if [[ -z "$local_serial" ]]; then
  echo "::error title=Invalid distribution certificate::Unable to read the certificate serial from IOS_DIST_CERT_P12_BASE64" >&2
  exit 1
fi

certificate_response="$(api_get /v1/certificates \
  --data-urlencode 'filter[certificateType]=DISTRIBUTION' \
  --data-urlencode 'limit=200')"
certificate_id="$(jq -r --arg serial "$local_serial" '
  .data[]
  | select((.attributes.serialNumber | ascii_upcase) == $serial)
  | .id
' <<<"$certificate_response" | head -n 1)"
if [[ -z "$certificate_id" ]]; then
  echo "::error title=Distribution certificate not found::The p12 certificate serial is not active in the Apple team" >&2
  exit 1
fi

device_1_id="$(ensure_device "$KAZUMI_DEVICE_1_NAME" "$KAZUMI_DEVICE_1_UDID")"
device_2_id="$(ensure_device "$KAZUMI_DEVICE_2_NAME" "$KAZUMI_DEVICE_2_UDID")"
bundle_resource_id="$(ensure_bundle_id)"

profile_name="Kazumi Internal Ad Hoc $(date -u +%Y%m%dT%H%M%SZ)"
profile_body="$(jq -n \
  --arg name "$profile_name" \
  --arg bundle "$bundle_resource_id" \
  --arg certificate "$certificate_id" \
  --arg device1 "$device_1_id" \
  --arg device2 "$device_2_id" \
  '{data:{
    type:"profiles",
    attributes:{name:$name,profileType:"IOS_APP_ADHOC"},
    relationships:{
      bundleId:{data:{type:"bundleIds",id:$bundle}},
      certificates:{data:[{type:"certificates",id:$certificate}]},
      devices:{data:[{type:"devices",id:$device1},{type:"devices",id:$device2}]}
    }
  }}')"
profile_response="$(api_post /v1/profiles "$profile_body")"
profile_path="$work_dir/kazumi.mobileprovision"
jq -er '.data.attributes.profileContent' <<<"$profile_response" | base64 --decode > "$profile_path"

profile_plist="$work_dir/profile.plist"
security cms -D -i "$profile_path" > "$profile_plist"
profile_uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$profile_plist")"
profile_expiry="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$profile_plist")"
profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$profile_plist")"
if [[ "$profile_app_id" != "$APPLE_TEAM_ID.$KAZUMI_BUNDLE_ID" ]]; then
  echo "::error title=Profile bundle mismatch::Expected $APPLE_TEAM_ID.$KAZUMI_BUNDLE_ID, got $profile_app_id" >&2
  exit 1
fi
for udid in "$KAZUMI_DEVICE_1_UDID" "$KAZUMI_DEVICE_2_UDID"; do
  if ! /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$profile_plist" | grep -Fq "$udid"; then
    echo "::error title=Profile device mismatch::$udid is missing from the generated profile" >&2
    exit 1
  fi
done

security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$p12_path" -k "$keychain_path" \
  -P "$IOS_DIST_CERT_P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security -f pkcs12 -A
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$keychain_password" "$keychain_path" >/dev/null
identity="$(security find-identity -v -p codesigning "$keychain_path" \
  | awk '/Apple Distribution/ {print $2; exit}')"
if [[ -z "$identity" ]]; then
  echo "::error title=No Apple Distribution identity::The imported p12 has no usable distribution identity" >&2
  exit 1
fi

unsigned_ipa="$work_dir/Kazumi_ios_${KAZUMI_VERSION}_no_sign.ipa"
curl --fail --location --silent --show-error \
  "https://github.com/Predidit/Kazumi/releases/download/${KAZUMI_VERSION}/Kazumi_ios_${KAZUMI_VERSION}_no_sign.ipa" \
  --output "$unsigned_ipa"
actual_sha256="$(shasum -a 256 "$unsigned_ipa" | awk '{print $1}')"
if [[ "$actual_sha256" != "$KAZUMI_UNSIGNED_SHA256" ]]; then
  echo "::error title=Unsigned IPA checksum mismatch::Expected $KAZUMI_UNSIGNED_SHA256, got $actual_sha256" >&2
  exit 1
fi

unpacked="$work_dir/unpacked"
mkdir -p "$unpacked"
unzip -q "$unsigned_ipa" -d "$unpacked"
app_path="$(find "$unpacked/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$app_path" ]]; then
  echo "::error title=Malformed IPA::Payload contains no .app bundle" >&2
  exit 1
fi
if find "$app_path" -type d -name '*.appex' -print -quit | grep -q .; then
  echo "::error title=Unexpected app extension::The upstream package gained an extension; update the re-signing procedure" >&2
  exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $KAZUMI_BUNDLE_ID" "$app_path/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Kazumi Internal' "$app_path/Info.plist"
cp "$profile_path" "$app_path/embedded.mobileprovision"
rm -rf "$app_path/_CodeSignature"

entitlements_path="$work_dir/entitlements.plist"
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$profile_plist" > "$entitlements_path"
plutil -lint "$entitlements_path"

while IFS= read -r -d '' dylib; do
  codesign --force --sign "$identity" --keychain "$keychain_path" \
    --timestamp=none --preserve-metadata=identifier,flags "$dylib"
done < <(find "$app_path/Frameworks" -type f -name '*.dylib' -print0 2>/dev/null)

while IFS= read -r -d '' bundle; do
  codesign --force --sign "$identity" --keychain "$keychain_path" \
    --timestamp=none --preserve-metadata=identifier,flags "$bundle"
done < <(find "$app_path/Frameworks" -depth -type d -name '*.framework' -print0 2>/dev/null)

codesign --force --sign "$identity" --keychain "$keychain_path" \
  --timestamp=none --entitlements "$entitlements_path" "$app_path"
codesign --verify --deep --strict --verbose=4 "$app_path"

signed_entitlements="$work_dir/signed-entitlements.plist"
codesign -d --entitlements :- "$app_path" > "$signed_entitlements" 2>/dev/null
signed_app_id="$(/usr/libexec/PlistBuddy -c 'Print :application-identifier' "$signed_entitlements")"
if [[ "$signed_app_id" != "$profile_app_id" ]]; then
  echo "::error title=Signed entitlement mismatch::Expected $profile_app_id, got $signed_app_id" >&2
  exit 1
fi

mkdir -p "$KAZUMI_OUTPUT_DIR"
signed_ipa="$KAZUMI_OUTPUT_DIR/Kazumi_${KAZUMI_VERSION}_Internal_AdHoc.ipa"
ditto -c -k --keepParent "$unpacked/Payload" "$signed_ipa"

signed_sha256="$(shasum -a 256 "$signed_ipa" | awk '{print $1}')"
cat > "$KAZUMI_OUTPUT_DIR/signing-summary.txt" <<SUMMARY
Kazumi version: $KAZUMI_VERSION
Bundle ID: $KAZUMI_BUNDLE_ID
Profile: $profile_name
Profile UUID: $profile_uuid
Profile expires: $profile_expiry
Device 1: $KAZUMI_DEVICE_1_NAME ($KAZUMI_DEVICE_1_UDID)
Device 2: $KAZUMI_DEVICE_2_NAME ($KAZUMI_DEVICE_2_UDID)
Unsigned IPA SHA-256: $actual_sha256
Signed IPA SHA-256: $signed_sha256
SUMMARY

echo "signed IPA: $signed_ipa"
cat "$KAZUMI_OUTPUT_DIR/signing-summary.txt"
