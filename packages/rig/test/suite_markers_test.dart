import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rig/module.dart';
import 'package:rig/rig.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late StateDir stateDir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rig-markers-');
    stateDir = StateDir(tmp);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('suiteMarkerFile', () {
    test('files the marker under the kind, then the container', () {
      final marker = suiteMarkerFile(
        stateDir: stateDir,
        kind: 'postgres',
        containerId: 'abc123',
        resource: 'test_p_1_deadbeef',
      );

      expect(
        marker.path,
        p.join(tmp.path, 'markers', 'postgres', 'abc123', 'test_p_1_deadbeef'),
      );
    });

    test('keeps two kinds apart for the same container and resource', () {
      File markerFor(String kind) => suiteMarkerFile(
        stateDir: stateDir,
        kind: kind,
        containerId: 'abc123',
        resource: '3',
      );

      expect(markerFor('redis').path, isNot(markerFor('postgres').path));
    });

    test('rejects a kind that would escape the state directory', () {
      expect(
        () => suiteMarkerFile(
          stateDir: stateDir,
          kind: '../..',
          containerId: 'abc123',
          resource: 'x',
        ),
        throwsArgumentError,
      );
    });
  });

  group('markerStillClaims', () {
    final now = DateTime.utc(2026, 9, 21, 12);

    File plant({required Duration age}) {
      final marker = suiteMarkerFile(
        stateDir: stateDir,
        kind: 'postgres',
        containerId: 'abc123',
        resource: 'claimed',
      );
      marker.parent.createSync(recursive: true);
      marker.writeAsStringSync('');
      marker.setLastModifiedSync(now.subtract(age));
      return marker;
    }

    test('a marker nobody has is no claim', () {
      final absent = suiteMarkerFile(
        stateDir: stateDir,
        kind: 'postgres',
        containerId: 'abc123',
        resource: 'never-existed',
      );

      expect(markerStillClaims(absent, now: now), isFalse);
    });

    test('a fresh marker claims the resource', () {
      expect(
        markerStillClaims(plant(age: const Duration(minutes: 5)), now: now),
        isTrue,
      );
    });

    test('a marker exactly at the threshold still claims it', () {
      // The boundary belongs to the suite: being wrong the other way
      // reclaims a resource from a run that is still going.
      expect(
        markerStillClaims(plant(age: const Duration(hours: 24)), now: now),
        isTrue,
      );
    });

    test('a marker past the threshold has stopped claiming it', () {
      expect(
        markerStillClaims(
          plant(age: const Duration(hours: 24, minutes: 1)),
          now: now,
        ),
        isFalse,
      );
    });

    test('honours a caller-supplied threshold', () {
      expect(
        markerStillClaims(
          plant(age: const Duration(minutes: 5)),
          now: now,
          markerStaleAfter: const Duration(minutes: 1),
        ),
        isFalse,
      );
    });

    test('a marker that existed but is gone by the time its timestamp is '
        'read does not claim it, and does not throw', () {
      // The regression this pins: markerStillClaims used to call
      // existsSync() and then lastModifiedSync() as two separate
      // filesystem operations. Another suite's teardown deleting the
      // marker in the gap between them threw a FileSystemException that
      // nothing here caught. A single isolate cannot force that exact
      // gap, so this tests the equivalent observable instead — a marker
      // that is simply gone by the time this function looks at it, which
      // is what that gap leaves behind either way.
      final marker = plant(age: const Duration(minutes: 5));
      marker.deleteSync();

      expect(() => markerStillClaims(marker, now: now), returnsNormally);
      expect(markerStillClaims(marker, now: now), isFalse);
    });
  });
}
