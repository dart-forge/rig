// A tour of three features with no example elsewhere: a file placed before
// the container starts, waiting on a log line instead of a port or a
// healthcheck, and running a command inside the container afterward.
//
// This is a tour, not a test suite — a handful of assertions, not full
// coverage.
@Tags(['integration'])
library;

import 'dart:convert';

import 'package:rig/rig.dart';
import 'package:test/test.dart';

void main() {
  const greeting = 'hello from rig';

  final container = useContainer(
    ContainerSpec(
      image: 'alpine:3.20',
      // `files:` lands on disk between create and start — before the
      // container's own command runs — which is what lets that command read
      // it as its first act below. `ContainerLease.putFile` cannot do this:
      // it only writes into a container that is already running, too late
      // for something read once, at boot.
      files: [ContainerFile('/rig/greeting.txt', utf8.encode(greeting))],
      command: const [
        'sh',
        '-c',
        'echo "startup saw: \$(cat /rig/greeting.txt)"; sleep 300',
      ],
      // This image ships no healthcheck and opens no port, so neither
      // WaitFor.healthy nor WaitFor.port could ever succeed here. The log
      // line the command prints is the only signal there is.
      waitFor: const WaitFor.logMessage('startup saw:'),
    ),
  );

  test('the file was in place before the command ran', () async {
    final tail = await container.logTail();
    expect(tail, contains('startup saw: $greeting'));
  });

  test('exec looks inside the running container afterward', () async {
    final result = await container.exec(['cat', '/rig/greeting.txt']);
    expect(result.output, contains(greeting));
  });
}
