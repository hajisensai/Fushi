/// Application identity only; this never supplies the user's AniDB login.
class AniDbAppClientIdentity {
  const AniDbAppClientIdentity({required this.name, required this.version});
  const AniDbAppClientIdentity.unregistered()
      : name = '',
        version = null;

  final String name;
  final int? version;
}

/// Registered 2026-09-07: https://anidb.net/software/20715
/// UDP client 29913, active official version 1 (version record 27688).
/// `fushi` was already occupied; this is Fushi's separately registered identity.
const AniDbAppClientIdentity kBundledAniDbClient =
    AniDbAppClientIdentity(name: 'fushiplayer', version: 1);

/// An explicit custom client replaces the whole application identity pair.
/// Clearing the custom name selects the bundled client, never a mixed pair.
AniDbAppClientIdentity resolveAniDbAppClient({
  required String customName,
  required int? customVersion,
  AniDbAppClientIdentity bundled = kBundledAniDbClient,
}) =>
    customName.trim().isEmpty
        ? bundled
        : AniDbAppClientIdentity(
            name: customName.trim(), version: customVersion);
