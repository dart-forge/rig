import 'package:rig/rig.dart';
import 'package:test/test.dart';

void main() {
  group('DockerUnavailable', () {
    test('lists every path it looked at', () {
      final e = DockerUnavailable(
        searched: const [
          r'$DOCKER_HOST (not set)',
          '/var/run/docker.sock',
          '/Users/x/.docker/run/docker.sock',
        ],
      );

      expect(e.message, contains('Could not reach Docker'));
      expect(e.message, contains('/var/run/docker.sock'));
      expect(e.message, contains('/Users/x/.docker/run/docker.sock'));
      expect(e.message, contains(r'$DOCKER_HOST (not set)'));
      // Say how to fix it: a failure nobody can act on is not worth throwing.
      expect(e.message, contains('Is Docker running?'));
    });

    test('keeps the underlying cause in the message when there is one', () {
      final e = DockerUnavailable(
        searched: const ['/var/run/docker.sock'],
        cause: 'Connection refused',
      );

      expect(e.message, contains('Connection refused'));
    });
  });

  group('ReadyTimeout', () {
    test('says what it waited for, how long, and shows the log tail', () {
      final e = ReadyTimeout(
        containerId: 'abc123def456',
        waited: const Duration(seconds: 60),
        waitingFor: 'health status to become healthy',
        logTail: 'FATAL: password authentication failed',
      );

      expect(e.message, contains('health status to become healthy'));
      expect(e.message, contains('60s'));
      expect(e.message, contains('abc123def456'));
      expect(e.message, contains('FATAL: password authentication failed'));
    });

    test('says so explicitly when the container produced no logs', () {
      final e = ReadyTimeout(
        containerId: 'abc123def456',
        waited: const Duration(seconds: 5),
        waitingFor: 'port 5432 to accept connections',
        logTail: '',
      );

      expect(e.message, contains('(no output)'));
    });
  });

  group('EngineApiTooOld', () {
    test('names both versions', () {
      final e = EngineApiTooOld(used: 'v1.44', minSupported: '1.50');

      expect(e.message, contains('v1.44'));
      expect(e.message, contains('1.50'));
    });
  });

  group('EngineError', () {
    test('names the request that failed and keeps the body', () {
      final e = EngineError(
        method: 'POST',
        path: '/v1.44/containers/create',
        statusCode: 409,
        body: '{"message":"Conflict"}',
      );

      expect(e.message, contains('POST /v1.44/containers/create'));
      expect(e.message, contains('409'));
      expect(e.message, contains('Conflict'));
    });
  });

  group('ImagePullFailed', () {
    test('names the image and keeps the detail', () {
      final e = ImagePullFailed(
        image: 'postgres:16-alpine',
        detail: 'manifest unknown',
      );

      expect(e.message, contains('postgres:16-alpine'));
      expect(e.message, contains('manifest unknown'));
    });

    test('suggests checking the name, tag and a plain docker pull', () {
      final e = ImagePullFailed(
        image: 'postgres:16-alpine',
        detail: 'manifest unknown',
      );

      expect(e.message, contains('docker pull postgres:16-alpine'));
    });
  });

  group('ExecFailed', () {
    test('names the command, the exit code and the output', () {
      // The three values deliberately share no digits or words, so a
      // message missing any one of them cannot pass by accident because
      // another value happens to contain the same text.
      final e = ExecFailed(
        command: const ['sh', '-c', 'do-the-thing'],
        exitCode: 7,
        output: 'boom: disk is full',
      );

      expect(e.message, contains('sh -c do-the-thing'));
      expect(e.message, contains('7'));
      expect(e.message, contains('boom: disk is full'));
    });

    test('says so explicitly when the command produced no output', () {
      final e = ExecFailed(command: const ['true'], exitCode: 1, output: '');

      expect(e.message, contains('(no output)'));
    });
  });

  group('LeaseNotBound', () {
    test('points at the cause: used outside a test body', () {
      expect(LeaseNotBound().message, contains('setUpAll'));
    });
  });

  test('every exception prints its message through toString', () {
    final e = DockerUnavailable(searched: const ['/var/run/docker.sock']);
    expect(e.toString(), e.message);
  });
}
