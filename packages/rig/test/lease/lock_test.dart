import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:rig/rig.dart';
import 'package:rig/src/lease/lock.dart';
import 'package:test/test.dart';

/// Runs in a separate isolate: takes the lock, holds it, and reports the
/// window it held it for.
///
/// It reports an interval rather than "acquired" and "released" events so the
/// assertion does not depend on the arrival order of messages from two
/// isolates — only on whether the two holders were ever inside the lock at
/// the same moment.
Future<void> lockHolder((SendPort, String) args) async {
  final (port, lockPath) = args;
  await withExclusiveLock(lockPath, () async {
    final enteredAt = DateTime.now().microsecondsSinceEpoch;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final leftAt = DateTime.now().microsecondsSinceEpoch;
    port.send([enteredAt, leftAt]);
    return null;
  });
}

void main() {
  late Directory tmp;
  late String lockPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rig_lock_');
    lockPath = p.join(tmp.path, 'locks', 'abc.lock');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('runs the body and returns its value', () async {
    final result = await withExclusiveLock(lockPath, () async => 42);

    expect(result, 42);
  });

  test('releases the lock afterwards', () async {
    await withExclusiveLock(lockPath, () async => null);

    expect(Link(lockPath).existsSync(), isFalse);
  });

  test('releases the lock even when the body throws', () async {
    await expectLater(
      withExclusiveLock(lockPath, () async => throw StateError('boom')),
      throwsStateError,
    );

    expect(Link(lockPath).existsSync(), isFalse);
  });

  test('creates the parent directory', () async {
    await withExclusiveLock(lockPath, () async => null);

    expect(Directory(p.dirname(lockPath)).existsSync(), isTrue);
  });

  test('serialises two isolates in the same process', () async {
    // This is the case a File.lock based implementation gets wrong: POSIX
    // record locks belong to the process, so a second request from the same
    // process succeeds and both holders run at once. Isolate.spawn stays in
    // one process, which is exactly that situation.
    final held = <List<int>>[];
    final done = <Future<void>>[];

    for (var i = 0; i < 2; i++) {
      final receiver = ReceivePort();
      final finished = Completer<void>();
      receiver.listen((message) {
        held.add((message as List).cast<int>());
        receiver.close();
        finished.complete();
      });
      await Isolate.spawn(lockHolder, (receiver.sendPort, lockPath));
      done.add(finished.future);
    }

    await Future.wait(done);

    expect(held, hasLength(2));
    final [first, second] = held;
    final overlapped = first[0] < second[1] && second[0] < first[1];
    expect(
      overlapped,
      isFalse,
      reason:
          'two isolates were inside the lock at the same time: '
          'held $first and $second',
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('takes over a lock left behind by a crashed holder', () async {
    Link(lockPath)
      ..parent.createSync(recursive: true)
      ..createSync('held-at:2020-01-01T00:00:00.000Z|pid:1|token:dead');

    // The marker is old, so the lock can be taken over. If it could not be,
    // this call would time out instead.
    final result = await withExclusiveLock(
      lockPath,
      () async => 'took over',
      timeout: const Duration(seconds: 2),
    );

    expect(result, 'took over');
  });

  test(
    'two waiters racing on the same stale lock do not both get in',
    () async {
      // The bug this pins: both waiters judge the same marker stale, the first
      // deletes it and creates its own, and the second — still acting on the
      // judgement it made a moment earlier — deletes that fresh lock by path
      // and walks in alongside.
      Link(lockPath)
        ..parent.createSync(recursive: true)
        ..createSync('held-at:2020-01-01T00:00:00.000Z|pid:1|token:dead');

      final held = <List<int>>[];
      final done = <Future<void>>[];

      for (var i = 0; i < 2; i++) {
        final receiver = ReceivePort();
        final finished = Completer<void>();
        receiver.listen((message) {
          held.add((message as List).cast<int>());
          receiver.close();
          finished.complete();
        });
        await Isolate.spawn(lockHolder, (receiver.sendPort, lockPath));
        done.add(finished.future);
      }

      await Future.wait(done);

      expect(held, hasLength(2));
      final [first, second] = held;
      final overlapped = first[0] < second[1] && second[0] < first[1];
      expect(
        overlapped,
        isFalse,
        reason:
            'both waiters broke the same stale lock and entered together: '
            'held $first and $second',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('does not take over a fresh lock, and times out instead', () async {
    Link(lockPath)
      ..parent.createSync(recursive: true)
      ..createSync('held-at:${DateTime.now().toUtc().toIso8601String()}|pid:1');

    await expectLater(
      withExclusiveLock(
        lockPath,
        () async => null,
        timeout: const Duration(milliseconds: 200),
        retryInterval: const Duration(milliseconds: 20),
      ),
      throwsA(
        isA<LockTimeout>().having(
          (e) => e.message,
          'message',
          contains(lockPath),
        ),
      ),
    );
  });

  test('takes over a lock whose marker is unreadable', () async {
    Link(lockPath)
      ..parent.createSync(recursive: true)
      ..createSync('garbage that is not a timestamp');

    final result = await withExclusiveLock(
      lockPath,
      () async => 'took over',
      timeout: const Duration(seconds: 2),
    );

    expect(result, 'took over');
  });
}
