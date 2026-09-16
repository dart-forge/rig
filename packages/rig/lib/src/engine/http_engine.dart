import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../errors.dart';
import '../spec/container_spec.dart';
import 'docker_engine.dart';

/// Talks to a Docker daemon over its unix domain socket.
///
/// The CLI is not an API: its output format carries no compatibility promise,
/// so parsing it would be a permanent liability. Every other language's
/// testcontainers speaks the Engine API for the same reason.
///
/// Dart can do this with no extra dependency: `HttpClient.connectionFactory`
/// accepts a unix socket, so `dart:io` is the whole HTTP client.
final class HttpDockerEngine implements DockerEngine {
  HttpDockerEngine({required String socketPath, this.host = '127.0.0.1'})
    : _socketPath = socketPath,
      _client = HttpClient() {
    _client.connectionFactory = (uri, proxyHost, proxyPort) =>
        Socket.startConnect(
          InternetAddress(socketPath, type: InternetAddressType.unix),
          0,
        );
  }

  /// Pinned rather than omitted: a request with no version prefix is served
  /// as the daemon's newest API and would silently follow breaking changes.
  static const String apiVersion = 'v1.44';

  /// The address a test should connect to for a published port.
  final String host;

  final String _socketPath;
  final HttpClient _client;

  @override
  Future<void> ping() async {
    try {
      final res = await _send('GET', '/_ping');
      if (res.statusCode >= 400) {
        throw DockerUnavailable(
          searched: ['$_socketPath (answered ${res.statusCode})'],
          cause: res.text,
        );
      }
    } on SocketException catch (e) {
      throw DockerUnavailable(searched: [_socketPath], cause: e.message);
    } on HttpException catch (e) {
      throw DockerUnavailable(searched: [_socketPath], cause: e.message);
    }
  }

  @override
  Future<EngineVersion> version() async {
    final json = await _getJsonMap('/version');
    return EngineVersion(
      version: json['Version'] as String? ?? 'unknown',
      apiVersion: json['ApiVersion'] as String? ?? 'unknown',
      minApiVersion: json['MinAPIVersion'] as String? ?? '0.0',
    );
  }

  /// Throws [EngineApiTooOld] when the daemon no longer accepts [apiVersion].
  Future<void> ensureApiCompatible() async {
    final reported = await version();
    if (_isBelow(apiVersion, reported.minApiVersion)) {
      throw EngineApiTooOld(
        used: apiVersion,
        minSupported: reported.minApiVersion,
      );
    }
  }

  @override
  Future<void> close() async => _client.close(force: true);

  // ---- HTTP plumbing ----

  Future<_EngineResponse> _send(
    String method,
    String path, {
    Object? body,
  }) async {
    final uri = Uri.parse('http://localhost/$apiVersion$path');
    final request = await _client.openUrl(method, uri);
    if (body != null) {
      final encoded = utf8.encode(jsonEncode(body));
      request.headers.contentType = ContentType.json;
      request.headers.contentLength = encoded.length;
      request.add(encoded);
    } else {
      request.headers.contentLength = 0;
    }
    final response = await request.close();
    final bytes = <int>[];
    await response.forEach(bytes.addAll);
    return _EngineResponse(
      statusCode: response.statusCode,
      bytes: bytes,
      method: method,
      path: '/$apiVersion$path',
    );
  }

  /// Sends a request and throws [EngineError] for any error status.
  Future<_EngineResponse> _sendOk(
    String method,
    String path, {
    Object? body,
  }) async {
    final res = await _send(method, path, body: body);
    if (res.statusCode >= 400) {
      throw EngineError(
        method: res.method,
        path: res.path,
        statusCode: res.statusCode,
        body: res.text,
      );
    }
    return res;
  }

  Future<Map<String, Object?>> _getJsonMap(String path) async {
    final res = await _sendOk('GET', path);
    final decoded = jsonDecode(res.text);
    if (decoded is! Map<String, Object?>) {
      throw EngineError(
        method: 'GET',
        path: res.path,
        statusCode: res.statusCode,
        body: 'expected a JSON object, got: ${res.text}',
      );
    }
    return decoded;
  }

  /// True when [candidate] is lower than [minimum], comparing `major.minor`
  /// numerically. '1.9' is below '1.44', which string comparison gets wrong.
  static bool _isBelow(String candidate, String minimum) {
    final a = _parseApiVersion(candidate);
    final b = _parseApiVersion(minimum);
    if (a.major != b.major) return a.major < b.major;
    return a.minor < b.minor;
  }

  static ({int major, int minor}) _parseApiVersion(String raw) {
    final cleaned = raw.startsWith('v') ? raw.substring(1) : raw;
    final parts = cleaned.split('.');
    return (
      major: int.tryParse(parts.first) ?? 0,
      minor: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
    );
  }

  // Implemented in a later step. Throwing keeps anything from quietly
  // depending on a stub.
  @override
  Future<bool> imageExists(String image) => throw UnimplementedError();

  @override
  Future<void> pullImage(String image) => throw UnimplementedError();

  @override
  Future<List<ContainerSummary>> listContainers({
    Map<String, List<String>> filters = const {},
    bool all = true,
  }) => throw UnimplementedError();

  @override
  Future<String> createContainer(
    ContainerSpec spec,
    Map<String, String> labels,
  ) => throw UnimplementedError();

  @override
  Future<void> startContainer(String id) => throw UnimplementedError();

  @override
  Future<ContainerInspect> inspectContainer(String id) =>
      throw UnimplementedError();

  @override
  Future<String> logTail(String id, {int lines = 50}) =>
      throw UnimplementedError();

  @override
  Future<void> stopContainer(
    String id, {
    Duration timeout = const Duration(seconds: 10),
  }) => throw UnimplementedError();

  @override
  Future<void> removeContainer(String id) => throw UnimplementedError();
}

final class _EngineResponse {
  _EngineResponse({
    required this.statusCode,
    required this.bytes,
    required this.method,
    required this.path,
  });

  final int statusCode;
  final List<int> bytes;
  final String method;
  final String path;

  String get text => utf8.decode(bytes, allowMalformed: true);
}
