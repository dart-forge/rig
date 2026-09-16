import 'dart:convert';
import 'dart:io';

/// A request the fake engine received.
final class RecordedRequest {
  RecordedRequest({
    required this.method,
    required this.path,
    required this.body,
  });

  final String method;

  /// Path including the query string, exactly as it arrived.
  final String path;

  final String body;

  Map<String, Object?> get json => jsonDecode(body) as Map<String, Object?>;
}

/// A Docker daemon stand-in that speaks real HTTP over a real unix socket.
///
/// The point is to exercise rig's request building and response parsing
/// through an actual socket, without a daemon.
final class FakeEngineServer {
  FakeEngineServer._(this._server, this._socketPath);

  final HttpServer _server;
  final String _socketPath;
  final List<RecordedRequest> requests = [];
  final List<_Route> _routes = [];

  static Future<FakeEngineServer> start(String socketPath) async {
    final socket = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    final server = HttpServer.listenOn(socket);
    final fake = FakeEngineServer._(server, socketPath);
    fake._serve();
    return fake;
  }

  /// Answers [method] requests whose path starts with [path].
  ///
  /// Later registrations win, so a test can override a default.
  void on(
    String method,
    String path, {
    int status = 200,
    Object? json,
    String? body,
  }) {
    _routes.insert(
      0,
      _Route(
        method: method,
        pathPrefix: path,
        status: status,
        body: body ?? (json == null ? '' : jsonEncode(json)),
        isJson: json != null,
      ),
    );
  }

  void _serve() {
    _server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      final target =
          '${request.uri.path}'
          '${request.uri.hasQuery ? '?${request.uri.query}' : ''}';
      requests.add(
        RecordedRequest(method: request.method, path: target, body: body),
      );

      final route = _routes.firstWhere(
        (r) =>
            r.method == request.method &&
            request.uri.path.startsWith(r.pathPrefix),
        orElse: () => _Route(
          method: request.method,
          pathPrefix: '',
          status: 404,
          body: '{"message":"fake engine has no route for $target"}',
          isJson: true,
        ),
      );

      request.response.statusCode = route.status;
      if (route.isJson) {
        request.response.headers.contentType = ContentType.json;
      }
      request.response.write(route.body);
      await request.response.close();
    });
  }

  Future<void> close() async {
    await _server.close(force: true);
    final file = File(_socketPath);
    if (file.existsSync()) file.deleteSync();
  }
}

final class _Route {
  _Route({
    required this.method,
    required this.pathPrefix,
    required this.status,
    required this.body,
    required this.isJson,
  });

  final String method;
  final String pathPrefix;
  final int status;
  final String body;
  final bool isJson;
}
