# Application outbound networking

The application preference readers and `resolveAppProxyDirective` own automatic,
manual and direct routing. Local and private destinations retain direct routing.
Torrent retains its separate opt-in transport policy. Platform proxy discovery
must finish before starting public clients, including dictionary popup startup.

## Native consumers

Native HTTP engines cannot use Dart's `HttpClient.findProxy`. The authenticated
loopback relay in `app_native_proxy.dart` applies the same decision to each HTTP
request and CONNECT tunnel. Redirects and media segments remain subject to the
same policy; encrypted tunnel content is not inspected. Existing tunnels finish
on their established route; subsequent connections read current settings.

Mihon uses a separate authenticated loopback policy callback, allowing OkHttp to
retain extension cookies, interceptors and connection behavior while obtaining
the current per-URL policy. A failed request must not terminate the shared JVM
and interrupt unrelated searches.

Mihon shared clients use HTTP/1.1 and no idle connection reuse. Evicting only idle
connections on a policy change is insufficient: an active HTTP/2 connection can
accept new streams, and an active HTTP/1 connection can return to the old pool
later. This trades extra connection handshakes for deterministic routing without
aborting in-flight downloads. A future optimization requires policy-isolated
connection pools, including clients derived by third-party extensions.

## Security boundary

Both services bind IPv4 loopback on an OS-selected port and require a random
per-process credential. Credentials are not source-site request headers and must
not be logged. Upstream manual credentials are returned only for the selected
manual proxy, never for a direct target or an automatic proxy. Proxy challenge
handling is bounded. Native relay access credentials are private process data;
they are distinct from the user's proxy password. These services do not defend
against code already executing with the user's permissions, including trusted
third-party manga extensions.

Plain HTTP forwarding strips hop-by-hop and proxy-authentication headers; HTTPS
uses byte tunnels and leaves certificate verification to the native client.
The relay does not alter source identity, TLS trust, private-target bypass, or
the user's direct-mode choice. Open tunnels and clients must be closed with the
owning service. Proxy policy changes apply to new requests/connections, not
already downloaded image cache entries or established transport sessions.

## Images and self-hosted services

Image providers use application HTTP factories. Disk cache identifiers and
resized image behavior remain compatible with existing caches. Headers form
part of image identity so requests with different source credentials do not
share an inappropriate in-memory image. Public WebDAV uses the same factory;
paired certificate-pinned peers retain their dedicated transport.

## Validation

Tests use local HTTP proxies and socket endpoints to verify real routing,
authentication, local bypass, mode transitions and cache behavior. Native build
and device checks are reported separately from Dart/Kotlin/Rust tests; a source
change alone does not establish that an installed native bundle is repaired.

Interactive Cloudflare challenges use isolated browsers (BUG-2275). Android
opens an explicitly requested, non-exported Activity in `:network_challenge`,
with its own WebView data directory and process-local proxy override. Only that
process waits for the proxy configuration before navigating. The application
process and reader retain their existing WebView configuration. Android 9 and a
WebView with proxy-override support are required; unsupported configurations
report an error instead of silently using a different network route.

On iOS 17 / macOS 14 and newer, the native challenge modal owns a non-persistent
WKWebsiteDataStore with its own proxyConfigurations. Proxy failover is disabled,
and the local relay has its own authentication credential. Older Apple versions
cannot silently fall back to system browsing when manual/direct was requested.

Challenge browsers use a separate public-target-only instance of the native
relay. Local URL destinations are rejected for HTTP and CONNECT even if a
service worker or WebSocket skips the browser's navigation callbacks. This also
prevents a local origin from impersonating the relay's HTTP-auth realm in
Android callbacks, which do not expose an `isProxy` flag. DNS resolution is not
performed before routing: domains that only resolve through the user's proxy
must continue to work. This URL restriction is not a general DNS-rebinding
sandbox; source code remains subject to the browser's origin rules.

Only new clearance cookies for the challenged origin are merged back; an
unchanged clearance does not complete verification. Existing login cookies are
not copied into the isolated browser because the host cookie representations
do not preserve all HttpOnly/SameSite metadata. Login cookies remain in the
source session and are preserved when the clearance is merged. The actual
source User-Agent is preserved.
Cancel, load failure and renderer/process death do not retry the source. An
explicit successful verification triggers the existing retry action. Ordinary
background searches never open the Android verification Activity.

2026-09-08: centralize missing image, native and popup-startup network assembly
after multi-source manga connection failures (BUG-2272).
