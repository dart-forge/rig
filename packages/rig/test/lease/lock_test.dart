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

  group('breaking a stale lock', () {
    // The race these pin: two waiters judge the same marker stale, the first
    // deletes it and creates its own, and the second — still acting on the
    // judgement it made a moment earlier — deletes that fresh lock and walks
    // in alongside. Driving the decision directly makes the interleaving
    // exact; racing two isolates does not reach the window reliably.
    const stale = 'held-at:2020-01-01T00:00:00.000Z|pid:1|token:dead';
    const fresh = 'held-at:2026-09-16T00:00:00.000Z|pid:2|token:beef';

    test('removes it while it is still the lock that was judged', () {
      Link(lockPath)
        ..parent.createSync(recursive: true)
        ..createSync(stale);

      breakStaleLockIfUnchanged(Link(lockPath), stale);

      expect(Link(lockPath).existsSync(), isFalse);
    });

    test('leaves it alone once someone else has taken the lock', () {
      Link(lockPath)
        ..parent.createSync(recursive: true)
        ..createSync(stale);
      // A faster waiter broke the stale lock and took it.
      Link(lockPath).deleteSync();
      Link(lockPath).createSync(fresh);

      breakStaleLockIfUnchanged(Link(lockPath), stale);

      expect(
        Link(lockPath).existsSync(),
        isTrue,
        reason: 'that lock belongs to whoever created it, not to us',
      );
      expect(Link(lockPath).targetSync(), fresh);
    });

    test('is a no-op when the lock is already gone', () {
      Directory(p.dirname(lockPath)).createSync(recursive: true);

      expect(
        () => breakStaleLockIfUnchanged(Link(lockPath), stale),
        returnsNormally,
      );
    });
  });

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

  test(
    'gives up instead of spinning when a stale lock cannot be removed',
    () async {
      // The stale branch retries with no sleep, so an undeletable stale lock
      // would spin forever if the deadline were only checked on the waiting
      // branch. An unwritable directory is the cheapest way to make the delete
      // fail for real.
      final dir = Directory(p.dirname(lockPath))..createSync(recursive: true);
      Link(lockPath)
          .createSync('held-at:2020-01-01T00:00:00.000Z|pid:1|token:dead');
      await Process.run('chmod', ['500', dir.path]);
      addTearDown(() => Process.run('chmod', ['700', dir.path]));

      await expectLater(
        withExclusiveLock(
          lockPath,
          () async => null,
          timeout: const Duration(milliseconds: 200),
          retryInterval: const Duration(milliseconds: 20),
        ),
        throwsA(isA<LockTimeout>()),
      );
    },
  );

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
