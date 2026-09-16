import '../engine/docker_engine.dart';
import '../errors.dart';
import '../spec/container_spec.dart';
import 'acquire.dart';

/// A container a test is using.
///
/// Called a lease rather than a container because holding one does not mean
/// owning one: [release] removes a dedicated container, and lets go of a
/// shared one without touching it. A name like `RunningContainer` invites the
/// reader to expect a stop that will not happen.
final class ContainerLease {
  /// A lease whose container will be acquired later, in `setUpAll`.
  ///
  /// [engineOf] is called lazily because the engine is connected in that same
  /// `setUpAll`, after this lease has already been handed to the caller.
  ContainerLease.pending(this._engineOf);

  /// A lease over a container that is already running.
  ContainerLease.of(DockerEngine engine, AcquiredContainer acquired)
    : _engineOf = (() => engine),
      _acquired = acquired;

  final DockerEngine Function() _engineOf;
  AcquiredContainer? _acquired;
  bool _released = false;

  /// Attaches the acquired container. Called by `useContainer`.
  void bind(AcquiredContainer acquired) => _acquired = acquired;

  /// The address to connect to.
  String get host => _require().host;

  String get containerId => _require().containerId;

  Lifetime get lifetime => _require().lifetime;

  /// True when this container was already running and got reused.
  bool get reused => _require().reused;

  /// The host port Docker chose for [containerPort].
  int port(int containerPort) {
    final acquired = _require();
    final mapped = acquired.hostPorts[containerPort];
    if (mapped == null) {
      throw PortNotPublished(
        containerPort: containerPort,
        published: acquired.hostPorts.keys.toList()..sort(),
      );
    }
    return mapped;
  }

  /// `host:port` for [containerPort].
  String endpoint(int containerPort) => '$host:${port(containerPort)}';

  /// The tail of the container's output.
  Future<String> logTail({int lines = 50}) =>
      _engineOf().logTail(containerId, lines: lines);

  /// Let go of the container.
  ///
  /// A dedicated container is stopped and removed. A shared one is left
  /// running: the next run reuses it instead of paying for startup, and
  /// deciding "am I the last user" is not answerable when suites run in
  /// parallel isolates.
  Future<void> release() async {
    final acquired = _acquired;
    if (acquired == null || _released) return;
    _released = true;

    if (acquired.lifetime == Lifetime.dedicated) {
      final engine = _engineOf();
      await engine.stopContainer(acquired.containerId);
      await engine.removeContainer(acquired.containerId);
    }
  }

  AcquiredContainer _require() {
    final acquired = _acquired;
    if (acquired == null) throw const LeaseNotBound();
    return acquired;
  }
}
