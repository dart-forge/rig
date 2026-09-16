import 'package:rig/rig.dart';
import 'package:test/test.dart';

void main() {
  const spec = ContainerSpec(
    image: 'postgres:16-alpine',
    env: {'POSTGRES_USER': 'test', 'POSTGRES_DB': 'test_db'},
    exposedPorts: [5432],
    waitFor: WaitFor.healthy(),
  );

  group('buildRigLabels', () {
    test('marks the container as rig-made', () {
      final labels = buildRigLabels(
        spec: spec,
        hash: 'abc123',
        project: 'aim_postgres',
      );

      expect(labels[rigMarkerLabel], '1');
    });

    test('carries the hash, lifetime and project', () {
      final labels = buildRigLabels(
        spec: spec,
        hash: 'abc123',
        project: 'aim_postgres',
      );

      expect(labels[rigHashLabel], 'abc123');
      expect(labels[rigLifetimeLabel], 'shared');
      expect(labels[rigProjectLabel], 'aim_postgres');
    });

    test('records dedicated lifetime too, so a leak can still be pruned', () {
      const dedicated = ContainerSpec(
        image: 'x',
        waitFor: WaitFor.healthy(),
        lifetime: Lifetime.dedicated,
      );

      final labels = buildRigLabels(spec: dedicated, hash: 'h', project: 'p');

      expect(labels[rigMarkerLabel], '1');
      expect(labels[rigLifetimeLabel], 'dedicated');
    });

    test('keeps the caller own labels', () {
      const annotated = ContainerSpec(
        image: 'x',
        waitFor: WaitFor.healthy(),
        labels: {'team': 'payments'},
      );

      final labels = buildRigLabels(spec: annotated, hash: 'h', project: 'p');

      expect(labels['team'], 'payments');
    });

    test('rig labels win over a caller label of the same name', () {
      const hostile = ContainerSpec(
        image: 'x',
        waitFor: WaitFor.healthy(),
        labels: {rigHashLabel: 'not-the-real-hash'},
      );

      final labels = buildRigLabels(spec: hostile, hash: 'real', project: 'p');

      expect(labels[rigHashLabel], 'real');
    });

    test('does not record a creation time: Docker already reports one', () {
      final labels = buildRigLabels(spec: spec, hash: 'h', project: 'p');

      expect(labels.keys.any((k) => k.contains('created')), isFalse);
    });
  });

  group('summarizeSpec', () {
    test('leads with the image', () {
      expect(summarizeSpec(spec), startsWith('postgres:16-alpine'));
    });

    test('mentions the exposed ports', () {
      expect(summarizeSpec(spec), contains('5432'));
    });

    test('lists env keys but never their values', () {
      final summary = summarizeSpec(spec);

      expect(summary, contains('POSTGRES_USER'));
      expect(
        summary,
        isNot(contains('test_db')),
        reason: 'a summary is shown to humans; values can be secrets',
      );
    });

    test('stays within the Docker label budget', () {
      final wide = ContainerSpec(
        image: 'x',
        waitFor: const WaitFor.healthy(),
        env: {for (var i = 0; i < 200; i++) 'VERY_LONG_ENV_NAME_$i': 'v'},
      );

      expect(summarizeSpec(wide).length, lessThanOrEqualTo(200));
    });
  });

  group('RigLabels.tryParse', () {
    test('round-trips what buildRigLabels wrote', () {
      final labels = buildRigLabels(
        spec: spec,
        hash: 'abc123',
        project: 'aim_postgres',
      );

      final parsed = RigLabels.tryParse(labels);

      expect(parsed, isNotNull);
      expect(parsed!.hash, 'abc123');
      expect(parsed.lifetime, Lifetime.shared);
      expect(parsed.project, 'aim_postgres');
      expect(parsed.summary, startsWith('postgres:16-alpine'));
    });

    test('returns null for a container rig did not make', () {
      expect(RigLabels.tryParse({'com.example.thing': '1'}), isNull);
    });

    test('returns null when the marker is there but the hash is missing', () {
      expect(RigLabels.tryParse({rigMarkerLabel: '1'}), isNull);
    });

    test('treats an unknown lifetime as dedicated, the safer reading', () {
      final parsed = RigLabels.tryParse({
        rigMarkerLabel: '1',
        rigHashLabel: 'h',
        rigLifetimeLabel: 'something-new',
      });

      expect(
        parsed!.lifetime,
        Lifetime.dedicated,
        reason: 'never reuse a container whose sharing intent is unclear',
      );
    });

    test('tolerates a missing project and summary', () {
      final parsed = RigLabels.tryParse({
        rigMarkerLabel: '1',
        rigHashLabel: 'h',
        rigLifetimeLabel: 'shared',
      });

      expect(parsed!.project, isEmpty);
      expect(parsed.summary, isEmpty);
    });
  });
}
