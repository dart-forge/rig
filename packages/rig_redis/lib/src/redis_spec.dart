import 'package:rig/rig.dart';

/// The container a Redis of this shape needs.
///
/// Why [databases] defaults to 64 rather than the official image's own
/// default of 16: a shared container is reused by any suite whose spec
/// hashes the same, and that sharing crosses project boundaries too — a
/// container this module starts is shared by rig's own tests and by every
/// other project on the machine asking for the same configuration, not just
/// by the suites of one project. So 16 databases is not "16 per project" —
/// it is 16 total, split between however many projects and suites happen to
/// land on the same container. 64 gives that shared pool more headroom.
ContainerSpec redisSpec({
  String version = '7-alpine',
  String? password,
  int databases = 64,
  Lifetime lifetime = Lifetime.shared,
  Map<String, String> labels = const {},
}) {
  final flags = [
    if (password != null) ...['--requirepass', password],
    '--databases',
    '$databases',
  ];

  // Unauthenticated when there is no password to give it; otherwise the
  // probe itself has to authenticate, or a password-protected server would
  // never pass its own healthcheck and `waitFor: WaitFor.healthy()` would
  // time out on every container this module ever starts with a password —
  // confirmed against a real daemon, which is exactly what happened before
  // this authenticated. `--no-auth-warning` keeps `-a`'s own warning
  // ("Using a password with '-a' ... may not be safe") off of the combined
  // output Docker's exec API hands back, which otherwise lands ahead of
  // whatever the command actually printed. The password is single-quoted
  // for a value containing whitespace; this module does not support one
  // containing a single quote.
  final probe = password == null
      ? 'redis-cli ping | grep -q PONG'
      : "redis-cli -a '$password' --no-auth-warning ping | grep -q PONG";

  final healthcheck = Healthcheck(
    // The official image ships no healthcheck at all, so this is injected.
    // `redis-cli ping` can print an error (e.g. NOAUTH) and still exit 0, so
    // the check pipes the output through grep instead of trusting the exit
    // code: verified against a real daemon, a server this probe cannot
    // authenticate to reports `unhealthy`, not `healthy` or `starting`
    // forever.
    test: ['CMD-SHELL', probe],
    interval: const Duration(milliseconds: 250),
    timeout: const Duration(seconds: 3),
    retries: 60,
  );

  return ContainerSpec(
    image: 'redis:$version',
    // `redis-server` has to lead the argument list and appear once: the
    // official entrypoint would otherwise treat a bare `--requirepass` as its
    // own first argument and run it as the image name, and passing
    // `redis-server` twice would start it with the second occurrence as a
    // config file path instead of a flag.
    command: ['redis-server', ...flags],
    exposedPorts: const [6379],
    labels: labels,
    healthcheck: healthcheck,
    waitFor: const WaitFor.healthy(),
    lifetime: lifetime,
  );
}
