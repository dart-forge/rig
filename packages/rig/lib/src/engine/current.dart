import 'connect.dart';
import 'docker_engine.dart';

Future<DockerEngine>? _pending;

/// The Docker client for this isolate, connected on first use.
///
/// One per isolate rather than one per process, because `dart test` runs each
/// test file in its own isolate and they share no memory. Sharing containers
/// between them is done through Docker's own labels, not through this.
Future<DockerEngine> currentEngine() => _pending ??= connectToDocker();

/// Makes [engine] the client this isolate uses. For rig's own tests and for
/// module tests.
void overrideEngine(DockerEngine engine) {
  _pending = Future.value(engine);
}

/// Drops the cached client, closing it if it was real.
Future<void> resetEngine() async {
  final existing = _pending;
  _pending = null;
  if (existing != null) await (await existing).close();
}
