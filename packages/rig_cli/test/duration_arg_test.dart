import 'package:rig_cli/src/duration_arg.dart';
import 'package:test/test.dart';

void main() {
  test('parses days, hours and minutes', () {
    expect(parseDurationArg('7d'), const Duration(days: 7));
    expect(parseDurationArg('12h'), const Duration(hours: 12));
    expect(parseDurationArg('30m'), const Duration(minutes: 30));
  });

  test('parses a bare number as days', () {
    expect(parseDurationArg('3'), const Duration(days: 3));
  });

  test('accepts zero, which means everything', () {
    expect(parseDurationArg('0'), Duration.zero);
  });

  test('rejects nonsense with a message naming the accepted forms', () {
    expect(
      () => parseDurationArg('soon'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('7d'),
        ),
      ),
    );
  });

  test('rejects a negative duration', () {
    expect(() => parseDurationArg('-1d'), throwsA(isA<FormatException>()));
  });
}
