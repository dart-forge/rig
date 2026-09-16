import 'dart:async';
import 'dart:io';

import '../engine/docker_engine.dart';
import '../errors.dart';
import 'wait_for.dart';

/// Injected so tests can move time without waiting for it.
typedef Now = DateTime Function();

/// Injected alongside [Now]; a fake sleeper advances the fake clock.
typedef Sleeper = Future<void> Function(Duration);

/// What a wait strategy is allowed to know about the container.
final class ReadyTarget {
  ReadyTarget({
    required this.containerId,
    required this.host,
    required this.hostPortOf,
  });

  final String containerId;

  /// The address to connect to for a published port.
  final String host;

  /// The host port Docker chose for a container port, or null when that port
  /// was not published.
  final int? Function(int containerPort) hostPortOf;
}

const Duration _defaultPollInterval = Duration(milliseconds: 250);
const Duration _connectTimeout = Duration(seconds: 2);
const int _logTailLines = 50;

/// Block until [strategy] is satisfied for [target].
///
/// Throws [ReadyTimeout] with the container's log tail when the strategy's
/// timeout runs out, [ContainerExited] when the container stops on its own,
/// and [NoHealthcheck] when a health wait has nothing to read.
Future<void> awaitReady({
  required WaitFor strategy,
  required DockerEngine engine,
  required ReadyTarget target,
  Now now = _systemNow,
  Sleeper sleep = _systemSleep,
  Duration pollInterval = _defaultPollInterval,
}) async {
  if (strategy is AllWait) {
    // Concurrently: the parts are independent, and serialising them would
    // add their timeouts together.
    await Future.wait<void>([
      for (final part in strategy.strategies)
        awaitReady(
          strategy: part,
          engine: engine,
          target: target,
          now: now,
          sleep: sleep,
          pollInterval: pollInterval,
        ),
    ]);
    return;
  }

  final deadline = now().add(strategy.timeout);

  while (true) {
    if (await _isSatisfied(strategy, engine, target)) return;

    if (!now().isBefore(deadline)) {
      throw await _timeoutError(strategy, engine, target);
    }
    await sleep(pollInterval);
  }
}

/// What to throw when the deadline runs out.
///
/// A [PortWait] or [HttpOkWait] never inspects the container while polling —
/// they only try to connect — so a container that crashed early looks
/// exactly like one that is merely slow to accept connections, right up
/// until the deadline. Checking once here, instead of assuming the container
/// is still running, is what keeps `ReadyTimeout`'s "docker exec into it"
/// advice from being handed out for a container that no longer exists to
/// exec into.
Future<RigException> _timeoutError(
  WaitFor strategy,
  DockerEngine engine,
  ReadyTarget target,
) async {
  final inspected = await engine.inspectContainer(target.containerId);
  if (!inspected.running) {
    return ContainerExited(
      containerId: target.containerId,
      logTail: await engine.logTail(target.containerId, lines: _logTailLines),
    );
  }

  return ReadyTimeout(
    containerId: target.containerId,
    waited: strategy.timeout,
    waitingFor: _waitingForText(strategy, target),
    logTail: await engine.logTail(target.containerId, lines: _logTailLines),
  );
}

/// Adds the reason a port check can never succeed, so the message says more
/// than "timed out".
String _waitingForText(WaitFor strategy, ReadyTarget target) {
  if (strategy is PortWait &&
      target.hostPortOf(strategy.containerPort) == null) {
    return '${strategy.description} '
        '(port ${strategy.containerPort} was not published by this spec)';
  }
  if (strategy is HttpOkWait &&
      target.hostPortOf(strategy.containerPort) == null) {
    return '${strategy.description} '
        '(port ${strategy.containerPort} was not published by this spec)';
  }
  return strategy.description;
}

Future<bool> _isSatisfied(
  WaitFor strategy,
  DockerEngine engine,
  ReadyTarget target,
) async {
  return switch (strategy) {
    HealthyWait() => await _isHealthy(engine, target),
    PortWait(:final containerPort) => await _accepts(
      target.host,
      target.hostPortOf(containerPort),
    ),
    HttpOkWait(:final containerPort, :final path, :final status) =>
      await _answers(
        target.host,
        target.hostPortOf(containerPort),
        path,
        status,
      ),
    // Handled above; listed so the switch stays exhaustive.
    AllWait() => false,
  };
}

Future<bool> _isHealthy(DockerEngine engine, ReadyTarget target) async {
  final inspected = await engine.inspectContainer(target.containerId);

  if (inspected.health == HealthStatus.none) {
    // Either the spec forgot a healthcheck, or the container is already gone.
    if (!inspected.running) {
      throw ContainerExited(
        containerId: target.containerId,
        logTail: await engine.logTail(target.containerId, lines: _logTailLines),
      );
    }
    throw NoHealthcheck(containerId: target.containerId);
  }

  if (!inspected.running) {
    throw ContainerExited(
      containerId: target.containerId,
      logTail: await engine.logTail(target.containerId, lines: _logTailLines),
    );
  }

  // An unhealthy container is not a verdict: Docker flips back to healthy as
  // soon as a probe succeeds, and a slow start often shows up this way.
  return inspected.health == HealthStatus.healthy;
}

Future<bool> _accepts(String host, int? port) async {
  if (port == null) return false;
  try {
    final socket = await Socket.connect(host, port, timeout: _connectTimeout);
    socket.destroy();
    return true;
  } on SocketException {
    return false;
  }
}

Future<bool> _answers(String host, int? port, String path, int status) async {
  if (port == null) return false;
  final client = HttpClient()..connectionTimeout = _connectTimeout;
  try {
    final request = await client.getUrl(Uri.parse('http://$host:$port$path'));
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode == status;
  } on SocketException {
    return false;
  } on HttpException {
    return false;
  } finally {
    client.close(force: true);
  }
}

DateTime _systemNow() => DateTime.now();

Future<void> _systemSleep(Duration d) => Future<void>.delayed(d);
