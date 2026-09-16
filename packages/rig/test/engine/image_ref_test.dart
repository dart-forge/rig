import 'package:rig/src/engine/image_ref.dart';
import 'package:test/test.dart';

void main() {
  test('splits a plain name and tag', () {
    expect(splitImageRef('postgres:16-alpine'), (
      name: 'postgres',
      tag: '16-alpine',
    ));
  });

  test('defaults to latest when no tag is given', () {
    expect(splitImageRef('redis'), (name: 'redis', tag: 'latest'));
  });

  test('keeps a registry port out of the tag', () {
    expect(splitImageRef('localhost:5000/team/app:1.2.3'), (
      name: 'localhost:5000/team/app',
      tag: '1.2.3',
    ));
  });

  test('defaults to latest for a registry with a port and no tag', () {
    expect(splitImageRef('localhost:5000/team/app'), (
      name: 'localhost:5000/team/app',
      tag: 'latest',
    ));
  });

  test('handles a digest reference', () {
    expect(splitImageRef('postgres@sha256:abc123'), (
      name: 'postgres',
      tag: 'sha256:abc123',
    ));
  });

  test('handles a namespaced name', () {
    expect(splitImageRef('bitnami/postgresql:16'), (
      name: 'bitnami/postgresql',
      tag: '16',
    ));
  });
}
