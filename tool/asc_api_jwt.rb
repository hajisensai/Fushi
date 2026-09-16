# App Store Connect API 的 ES256 JWT 生成器（唯一实现）。
#
# 读环境变量 APPSTORE_API_KEY_ID / APPSTORE_API_ISSUER_ID / APPSTORE_API_PRIVATE_KEY，
# 往 stdout 打一行 token（有效期 ~18 分钟，Apple 上限 20 分钟）。
#
# 消费方：tool/sign_kazumi_adhoc.sh、tool/asc_latest_build_number.sh。
# 用 ruby 而不是 openssl CLI：ES256 要把 DER 签名转成 r‖s 裸串，openssl 命令行做不到。
# GitHub 的 macos / ubuntu runner 都自带 ruby。
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
