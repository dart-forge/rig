/// How the server should authenticate a TCP connection.
enum PgAuth {
  /// The client sends the password in the clear and the server compares it
  /// against whatever is stored. Useful when the point is not the handshake.
  password,

  /// MD5 challenge-response.
  md5,

  /// SCRAM-SHA-256, the modern default.
  scram,
}

/// What a given auth mode needs from the container and from the server.
final class PgAuthSetup {
  const PgAuthSetup({
    required this.env,
    required this.serverFlags,
    required this.passwordEncryption,
  });

  /// Environment the official image reads at initialisation.
  final Map<String, String> env;

  /// Extra `postgres` arguments. Empty for every mode today; kept because an
  /// auth mode is the kind of thing that grows one.
  final List<String> serverFlags;

  /// The encryption the stored password must use, or null when it does not
  /// matter.
  ///
  /// This is the half that is easy to miss. `POSTGRES_HOST_AUTH_METHOD=md5`
  /// only writes `md5` into pg_hba; the password itself is hashed at
  /// initialisation with the server's default, which is SCRAM. Faced with an
  /// md5 line in pg_hba and a SCRAM verifier, the server authenticates with
  /// SCRAM — the connection succeeds and md5 is never exercised. So the
  /// password is re-hashed after startup, and the mode becomes something the
  /// test asserts rather than hopes for.
  final String? passwordEncryption;
}

PgAuthSetup setupFor(PgAuth auth) => switch (auth) {
  PgAuth.password => const PgAuthSetup(
    env: {'POSTGRES_HOST_AUTH_METHOD': 'password'},
    serverFlags: [],
    passwordEncryption: null,
  ),
  PgAuth.md5 => const PgAuthSetup(
    env: {'POSTGRES_HOST_AUTH_METHOD': 'md5'},
    serverFlags: [],
    passwordEncryption: 'md5',
  ),
  PgAuth.scram => const PgAuthSetup(
    env: {'POSTGRES_HOST_AUTH_METHOD': 'scram-sha-256'},
    serverFlags: [],
    passwordEncryption: 'scram-sha-256',
  ),
};
