import 'package:rig/src/warn_threshold.dart';
import 'package:test/test.dart';

void main() {
  group('warnThreshold', () {
    test('defaults to defaultWarnAboveContainers when unset', () {
      expect(warnThreshold(const {}), defaultWarnAboveContainers);
    });

    test('reads RIG_WARN_ABOVE from the environment', () {
      expect(warnThreshold({'RIG_WARN_ABOVE': '5'}), 5);
    });

    test('falls back to the default when the value is not a number', () {
      expect(warnThreshold({'RIG_WARN_ABOVE': 'nope'}), 20);
    });
  });
}
