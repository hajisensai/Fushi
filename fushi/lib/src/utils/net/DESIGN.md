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

Interactive Cloudflare challenge WebViews still use the platform browser network
configuration. Their application-manual-proxy behavior is not covered by these
HTTP adapters. A process-wide WebView proxy override would also affect the EPUB
reader and other concurrent WebViews, so it is not installed by a manga request.

2026-09-08: centralize missing image, native and popup-startup network assembly
after multi-source manga connection failures (BUG-2272).
