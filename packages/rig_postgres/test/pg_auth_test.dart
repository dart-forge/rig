import 'package:rig_postgres/src/pg_auth.dart';
import 'package:test/test.dart';

void main() {
  test('cleartext asks the server for password auth and re-hashes nothing', () {
    final setup = setupFor(PgAuth.password);

    expect(setup.env['POSTGRES_HOST_AUTH_METHOD'], 'password');
    expect(
      setup.passwordEncryption,
      isNull,
      reason: 'a cleartext password is compared against whatever is stored',
    );
  });

  test('md5 puts md5 in pg_hba and re-hashes the password as md5', () {
    // Both halves are needed. With pg_hba set to md5 but the password stored
    // as SCRAM, the server quietly authenticates with SCRAM instead, so a
    // container meant to exercise md5 never does.
    final setup = setupFor(PgAuth.md5);

    expect(setup.env['POSTGRES_HOST_AUTH_METHOD'], 'md5');
    expect(setup.passwordEncryption, 'md5');
  });

  test('scram states the encryption rather than trusting the default', () {
    final setup = setupFor(PgAuth.scram);

    expect(setup.env['POSTGRES_HOST_AUTH_METHOD'], 'scram-sha-256');
    expect(setup.passwordEncryption, 'scram-sha-256');
  });

  test('no auth mode contributes server flags on its own', () {
    for (final auth in PgAuth.values) {
      expect(setupFor(auth).serverFlags, isEmpty);
    }
  });
}
