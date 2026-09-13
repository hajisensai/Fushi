# Outbound network assembly

- Use `createAppHttpClient`, `createAppHttpIoClient` or `createAppDio` for public HTTP.
- Use `AppHttpImage` or `AppCachedHttpImage` for remote images.
- Await `installAppNetworkBindings` after preferences load in every app entry point.
- Native engines use the private endpoint from `ensureAppNativeProxyEndpoint`;
  Mihon uses its authenticated per-URL policy callback.
- Never log relay endpoints or proxy credentials. Preserve paired-peer TLS pinning
  and the separate torrent transport policy.

See [DESIGN.md](DESIGN.md) for routing, authentication and lifecycle boundaries.
