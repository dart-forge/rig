import 'package:rig_mysql/src/mysql_tls.dart';
import 'package:test/test.dart';

void main() {
  test('the server default needs no flags', () {
    // MySQL generates a self-signed certificate at initialisation and
    // accepts TLS with it. Leaving it alone is the state closest to what a
    // deployment actually looks like.
    expect(tlsServerFlags(const MySqlTls.serverDefault()), isEmpty);
  });

  test('turning TLS off stops the server generating a certificate', () {
    expect(
      tlsServerFlags(const MySqlTls.off()),
      contains('--auto-generate-certs=OFF'),
    );
  });

  test('both states are const, so a spec can be built at declaration time', () {
    // usePostgres's counterpart has to hand a finished spec to useContainer
    // before any setUpAll exists to await anything in, and useMySql is the
    // same. A state that could not be const would push spec construction
    // later than that.
    const a = MySqlTls.serverDefault();
    const b = MySqlTls.off();

    expect(a, isA<ServerDefaultTls>());
    expect(b, isA<NoTls>());
  });

  test('the two states are distinguishable by pattern matching', () {
    String describe(MySqlTls tls) => switch (tls) {
      ServerDefaultTls() => 'on',
      NoTls() => 'off',
    };

    expect(describe(const MySqlTls.serverDefault()), 'on');
    expect(describe(const MySqlTls.off()), 'off');
  });
}
