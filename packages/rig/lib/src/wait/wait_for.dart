/// How rig decides a container is usable.
///
/// A strategy is pure data: it says what to check, never how. The checking
/// lives in `awaitReady`. That split keeps a spec const-constructible, which
/// is what lets rig hash it and share containers between test suites.
sealed class WaitFor {
  const WaitFor();

  /// Poll the container's health status until Docker reports healthy.
  ///
  /// Needs a healthcheck. Most official images do not ship one, so rig can
  /// inject it: see `ContainerSpec.healthcheck`.
  const factory WaitFor.healthy({Duration timeout}) = HealthyWait;

  /// Connect to the host port that Docker mapped [containerPort] to.
  const factory WaitFor.port(int containerPort, {Duration timeout}) = PortWait;

  /// GET [path] on the host port mapped from [containerPort] until it answers
  /// [status].
  const factory WaitFor.httpOk(
    int containerPort, {
    String path,
    int status,
    Duration timeout,
  }) = HttpOkWait;

  /// Wait for all of [strategies], concurrently.
  const factory WaitFor.all(List<WaitFor> strategies) = AllWait;

  /// How long to keep trying before giving up.
  Duration get timeout;

  /// What rig is waiting for, phrased to drop into an error message after
  /// "Waited 60s for ...".
  String get description;
}

const _defaultTimeout = Duration(seconds: 60);

final class HealthyWait extends WaitFor {
  const HealthyWait({this.timeout = _defaultTimeout});

  @override
  final Duration timeout;

  @override
  String get description => 'health status to become healthy';
}

final class PortWait extends WaitFor {
  const PortWait(this.containerPort, {this.timeout = _defaultTimeout});

  final int containerPort;

  @override
  final Duration timeout;

  @override
  String get description => 'port $containerPort to accept connections';
}

final class HttpOkWait extends WaitFor {
  const HttpOkWait(
    this.containerPort, {
    this.path = '/',
    this.status = 200,
    this.timeout = _defaultTimeout,
  });

  final int containerPort;
  final String path;
  final int status;

  @override
  final Duration timeout;

  @override
  String get description =>
      'GET $path on port $containerPort to answer $status';
}

final class AllWait extends WaitFor {
  const AllWait(this.strategies);

  final List<WaitFor> strategies;

  @override
  Duration get timeout => strategies.fold(
    Duration.zero,
    (longest, s) => s.timeout > longest ? s.timeout : longest,
  );

  @override
  String get description => strategies.map((s) => s.description).join(' and ');
}
