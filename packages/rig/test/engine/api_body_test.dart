import 'package:rig/rig.dart';
import 'package:rig/src/engine/api_body.dart' show buildCreateBody;
import 'package:test/test.dart';

void main() {
  group('buildCreateBody', () {
    test('sends no NetworkingConfig when the spec has no network', () {
      const spec = ContainerSpec(image: 'x', waitFor: WaitFor.healthy());

      final body = buildCreateBody(spec, const {});

      expect(body.containsKey('NetworkingConfig'), isFalse);
      // HostConfig.NetworkMode is likewise never sent for a user network:
      // NetworkingConfig alone attaches the container, verified against a
      // real daemon (see the network brief's report).
      final hostConfig = body['HostConfig']! as Map<String, Object?>;
      expect(hostConfig.containsKey('NetworkMode'), isFalse);
    });

    test('names the rig-prefixed network in EndpointsConfig', () {
      const spec = ContainerSpec(
        image: 'x',
        waitFor: WaitFor.healthy(),
        network: ContainerNetwork('app'),
      );

      final body = buildCreateBody(spec, const {});

      final endpoints =
          (body['NetworkingConfig']!
                  as Map<String, Object?>)['EndpointsConfig']!
              as Map<String, Object?>;
      expect(endpoints.keys, ['rig-app']);
    });

    test('omits Aliases entirely when the spec has no alias', () {
      const spec = ContainerSpec(
        image: 'x',
        waitFor: WaitFor.healthy(),
        network: ContainerNetwork('app'),
      );

      final body = buildCreateBody(spec, const {});

      final endpoints =
          (body['NetworkingConfig']!
                  as Map<String, Object?>)['EndpointsConfig']!
              as Map<String, Object?>;
      final endpoint = endpoints['rig-app']! as Map<String, Object?>;
      expect(
        endpoint.containsKey('Aliases'),
        isFalse,
        reason: 'an empty Aliases is not the same as no Aliases to Docker',
      );
    });

    test('sends the alias when given', () {
      const spec = ContainerSpec(
        image: 'x',
        waitFor: WaitFor.healthy(),
        network: ContainerNetwork('app', alias: 'db'),
      );

      final body = buildCreateBody(spec, const {});

      final endpoints =
          (body['NetworkingConfig']!
                  as Map<String, Object?>)['EndpointsConfig']!
              as Map<String, Object?>;
      final endpoint = endpoints['rig-app']! as Map<String, Object?>;
      expect(endpoint['Aliases'], ['db']);
    });
  });
}
