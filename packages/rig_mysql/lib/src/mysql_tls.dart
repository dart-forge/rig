/// Whether the container speaks TLS.
///
/// Not nullable, and that is deliberate. `rig_postgres`'s counterpart takes a
/// nullable type where null means no TLS, because Postgres only turns TLS on
/// when it is handed a certificate. MySQL generates its own during
/// initialisation and accepts TLS by default, so "pass nothing" would mean
/// the opposite here — and the container with TLS off is exactly the one a
/// driver needs in order to exercise the public-key path of
/// caching_sha2_password. Spelling the states out keeps the call site honest.
///
/// Sealed rather than a `bool` or an `enum` because the state this does not
/// have yet — a certificate rig generates itself, so a test can check
/// verification against a CA it controls — would carry a common name and a
/// validity period. Neither a bool nor an enum grows into that without a
/// breaking change.
sealed class MySqlTls {
  const MySqlTls();

  /// Leave MySQL's own behaviour alone: a self-signed certificate generated
  /// at initialisation, and TLS accepted with it.
  const factory MySqlTls.serverDefault() = ServerDefaultTls;

  /// No TLS. The server generates no certificate and is given none, so a
  /// client asking for TLS is refused.
  const factory MySqlTls.off() = NoTls;
}

/// MySQL's own default: TLS on, with the certificate it generated itself.
final class ServerDefaultTls extends MySqlTls {
  const ServerDefaultTls();
}

/// TLS unavailable.
final class NoTls extends MySqlTls {
  const NoTls();
}

/// The `mysqld` arguments [tls] needs.
List<String> tlsServerFlags(MySqlTls tls) => switch (tls) {
  ServerDefaultTls() => const [],
  // Without this the server generates a certificate and key during
  // initialisation and accepts TLS with them. There is no certificate to
  // remove afterwards, so the only way to arrive at a server without TLS is
  // to stop it being created.
  NoTls() => const ['--auto-generate-certs=OFF'],
};
