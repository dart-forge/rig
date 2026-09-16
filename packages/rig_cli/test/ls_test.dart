import 'package:rig/engine.dart';
import 'package:rig/fake_engine.dart';
import 'package:rig_cli/src/ls.dart';
import 'package:test/test.dart';

void main() {
  late FakeDockerEngine engine;
  late List<String> lines;

  setUp(() {
    engine = FakeDockerEngine();
    lines = [];
  });

  Future<int> ls() =>
      runLs(engine: engine, out: lines.add, now: DateTime.utc(2026, 9, 16, 12));

  String output() => lines.join('\n');

  test('says so plainly when there is nothing', () async {
    expect(await ls(), 0);
    expect(output(), contains('No containers'));
  });

  test(
    'lists a container with its hash, summary, state, age and project',
    () async {
      engine.addContainer(
        labels: {
          rigMarkerLabel: '1',
          rigHashLabel: 'a1b2c3d4e5f60718',
          rigLifetimeLabel: 'shared',
          rigProjectLabel: 'aim_postgres',
          rigSummaryLabel: 'postgres:16-alpine ports=5432',
        },
        created: DateTime.utc(2026, 9, 14, 12),
      );

      await ls();

      expect(output(), contains('a1b2c3d4e5f60718'));
      expect(output(), contains('postgres:16-alpine'));
      expect(output(), contains('running'));
      expect(output(), contains('aim_postgres'));
      expect(output(), contains('2d'), reason: 'age, not a raw timestamp');
    },
  );

  test('has a header row', () async {
    engine.addContainer(labels: {rigMarkerLabel: '1', rigHashLabel: 'h'});

    await ls();

    expect(lines.first.toUpperCase(), contains('HASH'));
    expect(lines.first.toUpperCase(), contains('AGE'));
  });

  test('marks which ones are dedicated', () async {
    engine.addContainer(
      labels: {
        rigMarkerLabel: '1',
        rigHashLabel: 'h',
        rigLifetimeLabel: 'dedicated',
      },
    );

    await ls();

    expect(output(), contains('dedicated'));
  });

  test('only asks Docker for containers rig made', () async {
    await ls();

    expect(engine.calls, ['list']);
  });

  test('shows stopped containers too: they still take up space', () async {
    engine.addContainer(
      labels: {rigMarkerLabel: '1', rigHashLabel: 'h'},
      state: 'exited',
    );

    await ls();

    expect(output(), contains('exited'));
  });

  test('renders ages under a day in hours', () async {
    engine.addContainer(
      labels: {rigMarkerLabel: '1', rigHashLabel: 'h'},
      created: DateTime.utc(2026, 9, 16, 9),
    );

    await ls();

    expect(output(), contains('3h'));
  });
}
