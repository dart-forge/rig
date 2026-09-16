import 'package:rig/engine.dart';
import 'package:rig/fake_engine.dart';
import 'package:rig/rig.dart';
import 'package:test/test.dart';

void main() {
  // The cache is isolate-global, so each test starts from a clean one.
  setUp(resetEngine);
  tearDown(resetEngine);

  Future<DockerEngine> alwaysFails() async =>
      throw const DockerUnavailable(searched: ['/nope.sock']);

  test('does not remember a failed connection', () async {
    var attempts = 0;
    Future<DockerEngine> failing() {
      attempts++;
      return alwaysFails();
    }

    await expectLater(
      currentEngine(connect: failing),
      throwsA(isA<DockerUnavailable>()),
    );
    await expectLater(
      currentEngine(connect: failing),
      throwsA(isA<DockerUnavailable>()),
    );

    expect(
      attempts,
      2,
      reason:
          'Docker may have been starting up; one bad moment must not '
          'doom every later call in this isolate',
    );
  });

  test('remembers a successful connection', () async {
    final fake = FakeDockerEngine();
    var attempts = 0;
    Future<DockerEngine> succeeding() async {
      attempts++;
      return fake;
    }

    expect(await currentEngine(connect: succeeding), same(fake));
    expect(await currentEngine(connect: succeeding), same(fake));
    expect(attempts, 1);
  });

  test('overrideEngine wins over connecting', () async {
    final fake = FakeDockerEngine();
    overrideEngine(fake);

    expect(await currentEngine(connect: alwaysFails), same(fake));
  });

  test('resetEngine clears a poisoned cache without throwing', () async {
    await expectLater(
      currentEngine(connect: alwaysFails),
      throwsA(isA<DockerUnavailable>()),
    );

    await expectLater(resetEngine(), completes);
  });

  test('resetEngine closes the client it drops', () async {
    final fake = FakeDockerEngine();
    overrideEngine(fake);
    await currentEngine();

    await resetEngine();

    expect(fake.calls, contains('close'));
  });

  test('a later connect runs after a reset', () async {
    final first = FakeDockerEngine();
    final second = FakeDockerEngine();
    overrideEngine(first);
    expect(await currentEngine(), same(first));

    await resetEngine();
    overrideEngine(second);

    expect(await currentEngine(), same(second));
  });
}
