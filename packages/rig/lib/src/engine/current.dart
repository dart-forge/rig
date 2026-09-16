import 'connect.dart';
import 'docker_engine.dart';

Future<DockerEngine>? _pending;

/// The Docker client for this isolate, connected on first use.
///
/// One per isolate rather than one per process, because `dart test` runs each
/// test file in its own isolate and they share no memory. Sharing containers
/// between them is done through Docker's own labels, not through this.
///
/// A *failed* attempt is deliberately not remembered. Docker may simply have
/// been starting up, or a single ping may have been unlucky; caching the
/// failure would turn one bad moment into every later call in this isolate
/// failing with no retry. [connect] exists so rig's own tests can exercise
/// that without a daemon.
Future<DockerEngine> currentEngine({
  Future<DockerEngine> Function() connect = connectToDocker,
}) => _pending ??= _connectAndForgetOnFailure(connect);

Future<DockerEngine> _connectAndForgetOnFailure(
  Future<DockerEngine> Function() connect,
) async {
  try {
    return await connect();
  } on Object {
    _pending = null;
    rethrow;
  }
}

/// Makes [engine] the client this isolate uses. For rig's own tests and for
/// module tests.
void overrideEngine(DockerEngine engine) {
  _pending = Future.value(engine);
}

/// Drops the cached client, closing it if there is one to close.
///
/// Clearing the cache is the whole job, so a cached attempt that had already
/// failed is discarded quietly rather than rethrown: a caller reaching for
/// this is recovering from that failure, not asking to see it again.
Future<void> resetEngine() async {
  final existing = _pending;
  _pending = null;
  if (existing == null) return;
  try {
    await (await existing).close();
  } on Object {
    // Nothing to close, and nothing useful to say about a failure the caller
    // has already seen once.
  }
}
