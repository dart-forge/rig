import 'dart:async';
import 'dart:io';

import '../errors.dart';
import 'discovery.dart';
import 'docker_engine.dart';
import 'http_engine.dart';

const Duration _pingTimeout = Duration(seconds: 5);

/// Find a Docker daemon, check it answers and speaks a version rig knows,
/// and return a client for it.
///
/// Every step is bounded. A daemon that accepts the connection and then never
/// answers is the failure mode that makes a test suite hang forever, which is
/// the thing rig exists to remove.
Future<DockerEngine> connectToDocker({
  Map<String, String>? environment,
  String? home,
}) async {
  final env = environment ?? Platform.environment;
  final socket = discoverDockerSocket(
    environment: env,
    home: home ?? _homeDir(env),
  );

  final engine = HttpDockerEngine(socketPath: socket.path);
  try {
    await engine.ping().timeout(_pingTimeout);
    await engine.ensureApiCompatible().timeout(_pingTimeout);
  } on TimeoutException {
    await engine.close();
    throw DockerUnavailable(
      searched: ['${socket.path} (${socket.source})'],
      cause:
          'the socket accepted a connection but did not answer within '
          '${_pingTimeout.inSeconds}s',
    );
  } on SocketException catch (e) {
    // `ping` converts this itself, but the version check does not, and a
    // socket can go away between the two. Converting here covers both calls
    // in one place, so nothing escapes as a bare dart:io exception.
    await engine.close();
    throw DockerUnavailable(
      searched: ['${socket.path} (${socket.source})'],
      cause: e.message,
    );
  } on HttpException catch (e) {
    await engine.close();
    throw DockerUnavailable(
      searched: ['${socket.path} (${socket.source})'],
      cause: e.message,
    );
  } on Object {
    await engine.close();
    rethrow;
  }
  return engine;
}

String _homeDir(Map<String, String> env) =>
    env['HOME'] ?? env['USERPROFILE'] ?? '';
