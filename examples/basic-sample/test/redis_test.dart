// Declare the container your test needs, then talk to it.
//
// Run it: `dart test` from examples/basic-sample. It is a test
// rather than a script because that is how rig is used — `useContainer` calls
// `setUpAll` — and because CI runs it, which keeps it honest as the API moves.
@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:rig/rig.dart';
import 'package:test/test.dart';

void main() {
  // One declaration, at the top of main(). Nothing is started yet: rig does
  // that in its own setUpAll, so the container is up before your tests run
  // and every suite asking for this same spec shares one container.
  final redis = useContainer(
    const ContainerSpec(
      image: 'redis:7-alpine',
      exposedPorts: [6379],
      // The image has no healthcheck, so wait for the port to answer.
      waitFor: WaitFor.port(6379),
    ),
  );

  test('the container is ready to talk to', () async {
    // The port is whatever Docker assigned — never 6379 on the host. That is
    // the point: nothing collides with a Redis you already run locally.
    final socket = await Socket.connect(redis.host, redis.port(6379));
    addTearDown(socket.close);

    socket.write('*1\r\n\$4\r\nPING\r\n');
    final reply = await socket
        .map(utf8.decode)
        .first
        .timeout(const Duration(seconds: 5));

    expect(reply, '+PONG\r\n');
  });
}
