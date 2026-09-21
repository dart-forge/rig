/// How the server should store the password it authenticates with.
enum MySqlAuth {
  /// SHA-256 based, with a cache on the server. MySQL's default since 8.0,
  /// and the harder of the two to speak: a client the cache does not know
  /// has to send the password in a form the server can recover — in the
  /// clear over TLS, or encrypted with the server's public key without it.
  cachingSha2,

  /// The pre-8.0 default, still widely deployed. Not loaded by default in
  /// 8.4.
  nativePassword,
}

/// What a given auth mode needs from the server.
final class MySqlAuthSetup {
  const MySqlAuthSetup({required this.serverFlags, required this.plugin});

  /// Extra `mysqld` arguments.
  final List<String> serverFlags;

  /// The plugin the stored password must actually use.
  ///
  /// This is the half that is easy to miss, and the reason this is a field
  /// rather than something inferred from a server flag. The official image
  /// creates the user during initialisation and stores the password under
  /// whatever the server's default plugin is at that moment. Changing the
  /// default afterwards — or having asked for a different one on the command
  /// line — does not re-hash what is already stored. A connection then
  /// succeeds while never exercising the plugin the test asked for. So the
  /// container is started, and then the password is stored again under this
  /// plugin, which turns the auth mode into something a test asserts rather
  /// than hopes for.
  final String plugin;
}

/// What [auth] needs from the server.
MySqlAuthSetup setupFor(MySqlAuth auth) => switch (auth) {
  MySqlAuth.cachingSha2 => const MySqlAuthSetup(
    serverFlags: [],
    plugin: 'caching_sha2_password',
  ),
  MySqlAuth.nativePassword => const MySqlAuthSetup(
    // 8.4 does not load this plugin unless told to, and the option that
    // tells it (`--mysql-native-password=ON`) does not exist in 8.0 —
    // passing it there stops the server from starting at all. The `loose-`
    // prefix turns an unknown option into a warning instead of a fatal
    // error, so one spelling serves both versions and nothing here has to
    // parse a version string.
    serverFlags: ['--loose-mysql-native-password=ON'],
    plugin: 'mysql_native_password',
  ),
};
