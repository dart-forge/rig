import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../errors.dart';
import '../spec/container_spec.dart';
import 'api_body.dart';
import 'api_parse.dart';
import 'docker_engine.dart';
import 'image_ref.dart';
import 'log_frames.dart';
import 'tar.dart';

/// Talks to a Docker daemon over its unix domain socket.
///
/// The CLI is not an API: its output format carries no compatibility promise,
/// so parsing it would be a permanent liability. Every other language's
/// testcontainers speaks the Engine API for the same reason.
///
/// Dart can do this with no extra dependency: `HttpClient.connectionFactory`
/// accepts a unix socket, so `dart:io` is the whole HTTP client.
final class HttpDockerEngine implements DockerEngine {
  HttpDockerEngine({
    required String socketPath,
    this.requestTimeout = const Duration(seconds: 30),
    this.pullTimeout = const Duration(seconds: 300),
    this.buildTimeout = const Duration(seconds: 300),
  }) : _socketPath = socketPath,
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

  /// How long any request other than a pull may take before it is treated
  /// as failed. A daemon that accepts the socket and then never answers is
  /// the exact failure mode rig exists to remove, so nothing here waits
  /// unbounded.
  final Duration requestTimeout;

  /// A pull needs its own, much longer budget: a cold pull of a real image
  /// routinely takes minutes, not seconds.
  final Duration pullTimeout;

  /// A build needs the same kind of budget as a pull, for the same reason:
  /// a cold build (base image included) can take minutes. An unchanged
  /// context rebuilds in tens of milliseconds thanks to layer caching, so
  /// this is a ceiling for the worst case, not the common one.
  final Duration buildTimeout;

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
    } on EngineError catch (e) {
      // The only way _send throws EngineError from ping's own request is the
      // timeout below: the daemon accepted the socket and then never
      // answered, which is DockerUnavailable's story to tell, not this
      // method's own contract of "the daemon answered with an error".
      throw DockerUnavailable(searched: [_socketPath], cause: e.body);
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
    Duration? timeout,
  }) async {
    final budget = timeout ?? requestTimeout;
    final fullPath = '/$apiVersion$path';
    try {
      return await _sendOnce(method, path, fullPath, body).timeout(budget);
    } on TimeoutException {
      // Never an unbounded wait: a daemon that accepted the socket and then
      // never answered becomes an error naming the request and how long rig
      // waited, not a hang. Callers with a more specific contract (ping,
      // pullImage) translate this into their own exception type.
      throw EngineError(
        method: method,
        path: fullPath,
        statusCode: 0,
        body: 'Docker did not respond within ${_formatDuration(budget)}',
      );
    }
  }

  /// Whole seconds where that is exact, milliseconds otherwise — so a
  /// production-sized budget (30s, 300s) reads naturally and a short budget
  /// in a test is not rounded down to "0s".
  static String _formatDuration(Duration d) => d.inMilliseconds % 1000 == 0
      ? '${d.inSeconds}s'
      : '${d.inMilliseconds}ms';

  Future<_EngineResponse> _sendOnce(
    String method,
    String path,
    String fullPath,
    Object? body,
  ) async {
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
      path: fullPath,
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

  @override
  Future<List<ContainerSummary>> listContainers({
    Map<String, List<String>> filters = const {},
    bool all = true,
  }) async {
    final query = {
      'all': all ? '1' : '0',
      if (filters.isNotEmpty) 'filters': jsonEncode(filters),
    };
    final res = await _sendOk('GET', '/containers/json?${_query(query)}');
    final decoded = jsonDecode(res.text);
    if (decoded is! List) return const [];
    return [
      for (final item in decoded)
        if (item is Map<String, Object?>) parseSummary(item),
    ];
  }

  @override
  Future<String> createContainer(
    ContainerSpec spec,
    Map<String, String> labels,
  ) async {
    final res = await _sendOk(
      'POST',
      '/containers/create',
      body: buildCreateBody(spec, labels),
    );
    final json = jsonDecode(res.text);
    if (json is! Map<String, Object?> || json['Id'] is! String) {
      throw EngineError(
        method: 'POST',
        path: res.path,
        statusCode: res.statusCode,
        body: 'create returned no container id: ${res.text}',
      );
    }
    return json['Id']! as String;
  }

  @override
  Future<void> startContainer(String id) async {
    final res = await _send('POST', '/containers/$id/start');
    // 304 means it was already running, which is what the caller wanted.
    if (res.statusCode == 304) return;
    if (res.statusCode >= 400) {
      throw EngineError(
        method: 'POST',
        path: res.path,
        statusCode: res.statusCode,
        body: res.text,
      );
    }
  }

  @override
  Future<ContainerInspect> inspectContainer(String id) async =>
      parseInspect(await _getJsonMap('/containers/$id/json'));

  @override
  Future<String> logTail(String id, {int lines = 50}) async {
    final query = {'stdout': '1', 'stderr': '1', 'tail': '$lines'};
    final res = await _send('GET', '/containers/$id/logs?${_query(query)}');
    // Logs are read in order to build an error message. Throwing here would
    // replace the real failure with a less useful one.
    if (res.statusCode >= 400) return '';
    return demuxLogFrames(res.bytes);
  }

  @override
  Future<String> logs(String id) async {
    final query = {'stdout': '1', 'stderr': '1', 'tail': 'all'};
    final res = await _send('GET', '/containers/$id/logs?${_query(query)}');
    // Same reasoning as logTail: this is read to check a wait condition, not
    // to demand the container exists, so a failure reads as "no log" rather
    // than throwing.
    if (res.statusCode >= 400) return '';
    return demuxLogFrames(res.bytes);
  }

  @override
  Future<ExecResult> exec(String id, List<String> command) async {
    final created = await _sendOk(
      'POST',
      '/containers/$id/exec',
      body: {
        'AttachStdout': true,
        'AttachStderr': true,
        'Tty': false,
        'Cmd': command,
      },
    );

    final decoded = jsonDecode(created.text);
    final execId = decoded is Map<String, Object?> ? decoded['Id'] : null;
    if (execId is! String || execId.isEmpty) {
      throw EngineError(
        method: 'POST',
        path: created.path,
        statusCode: created.statusCode,
        body: 'exec create returned no exec id: ${created.text}',
      );
    }

    // Detach: false keeps the output on this response. Docker calls this a
    // hijacked stream, but with no stdin to write it reads like any other body.
    final started = await _sendOk(
      'POST',
      '/exec/$execId/start',
      body: {'Detach': false, 'Tty': false},
    );

    final inspected = await _getJsonMap('/exec/$execId/json');
    final code = inspected['ExitCode'];

    return ExecResult(
      // Never guess 0: reporting success for a command whose result is unknown
      // is the one wrong answer available here.
      exitCode: code is int ? code : -1,
      output: demuxLogFrames(started.bytes),
    );
  }

  @override
  Future<void> putArchive(String id, String path, List<int> tarBytes) async {
    final res = await _sendBytes(
      'PUT',
      '/containers/$id/archive?${_query({'path': path})}',
      bytes: tarBytes,
      contentType: 'application/x-tar',
    );
    // Docker's own 404 body calls the missing destination "the file", which
    // is backwards from what actually happened: the destination has to
    // already exist as a directory, and rig says that plainly instead.
    if (res.statusCode == 404) {
      throw CopyDestinationNotFound(containerId: id, directory: path);
    }
    if (res.statusCode >= 400) {
      throw EngineError(
        method: 'PUT',
        path: res.path,
        statusCode: res.statusCode,
        body: res.text,
      );
    }
  }

  @override
  Future<Uint8List> getArchive(String id, String path) async {
    final res = await _sendOk(
      'GET',
      '/containers/$id/archive?${_query({'path': path})}',
    );
    return Uint8List.fromList(res.bytes);
  }

  @override
  Future<void> stopContainer(
    String id, {
    // A container whose entrypoint is PID 1 with no SIGTERM handler ignores
    // the signal, so Docker waits the whole budget before SIGKILL. Every
    // dedicated suite pays this on every run, so it stays short.
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final res = await _send(
      'POST',
      '/containers/$id/stop?${_query({'t': '${timeout.inSeconds}'})}',
    );
    // 304: already stopped, which is the requested state.
    if (res.statusCode == 304 || res.statusCode < 400) return;
    throw EngineError(
      method: 'POST',
      path: res.path,
      statusCode: res.statusCode,
      body: res.text,
    );
  }

  @override
  Future<void> removeContainer(String id) async {
    final res = await _send(
      'DELETE',
      '/containers/$id?${_query({'v': '1', 'force': '1'})}',
    );
    // 404: already gone, which is what removing it was for.
    if (res.statusCode == 404 || res.statusCode < 400) return;
    throw EngineError(
      method: 'DELETE',
      path: res.path,
      statusCode: res.statusCode,
      body: res.text,
    );
  }

  @override
  Future<void> removeImage(String tag) async {
    final res = await _send(
      'DELETE',
      '/images/${Uri.encodeComponent(tag)}?${_query({'force': '1'})}',
    );
    // 404: already gone, which is what removing it was for.
    if (res.statusCode == 404 || res.statusCode < 400) return;
    throw EngineError(
      method: 'DELETE',
      path: res.path,
      statusCode: res.statusCode,
      body: res.text,
    );
  }

  @override
  Future<void> ensureNetwork(String name, Map<String, String> labels) async {
    final res = await _send(
      'POST',
      '/networks/create',
      body: {'Name': name, 'Labels': labels},
    );
    // 409: a network with this name already exists, which is exactly what
    // ensureNetwork was asked for.
    if (res.statusCode == 409 || res.statusCode < 400) return;
    throw EngineError(
      method: 'POST',
      path: res.path,
      statusCode: res.statusCode,
      body: res.text,
    );
  }

  @override
  Future<List<NetworkSummary>> listNetworks({
    Map<String, List<String>> filters = const {},
  }) async {
    final query = filters.isNotEmpty
        ? '?${_query({'filters': jsonEncode(filters)})}'
        : '';
    final res = await _sendOk('GET', '/networks$query');
    final decoded = jsonDecode(res.text);
    if (decoded is! List) return const [];
    return [
      for (final item in decoded)
        if (item is Map<String, Object?>) parseNetworkSummary(item),
    ];
  }

  @override
  Future<bool> removeNetwork(String id) async {
    final res = await _send('DELETE', '/networks/$id');
    // 404: already gone, which is what removing it was for.
    if (res.statusCode == 404 || res.statusCode < 400) return true;
    // 403: a container is still attached. This is the expected, common
    // outcome of `rig prune` walking every network it owns, not a failure of
    // the remove call — the caller decides what "still in use" means to it.
    if (res.statusCode == 403) return false;
    throw EngineError(
      method: 'DELETE',
      path: res.path,
      statusCode: res.statusCode,
      body: res.text,
    );
  }

  @override
  Future<bool> imageExists(String image) async {
    final res = await _send('GET', '/images/$image/json');
    return res.statusCode < 400;
  }

  @override
  Future<void> pullImage(String image) async {
    final ref = splitImageRef(image);
    final query = {'fromImage': ref.name, 'tag': ref.tag};
    final _EngineResponse res;
    try {
      res = await _send(
        'POST',
        '/images/create?${_query(query)}',
        timeout: pullTimeout,
      );
    } on EngineError catch (e) {
      // Only reachable via _send's own timeout on this request; a pull
      // failure gets ImagePullFailed's advice, not EngineError's.
      throw ImagePullFailed(image: image, detail: e.body);
    }

    if (res.statusCode >= 400) {
      throw ImagePullFailed(image: image, detail: res.text);
    }

    // Docker answers 200 and then reports failure inside the progress
    // stream, so the body has to be read even on success.
    final failure = _pullError(res.text);
    if (failure != null) {
      throw ImagePullFailed(image: image, detail: failure);
    }
  }

  /// The first error reported in a pull progress stream, if any.
  static String? _pullError(String body) {
    for (final line in body.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map && decoded['error'] != null) {
          return decoded['error'].toString();
        }
      } on FormatException {
        continue;
      }
    }
    return null;
  }

  @override
  Future<void> buildImage(ContainerBuild build, String tag) async {
    final tar = buildContextTar(Directory(build.context));
    final query = {
      't': tag,
      'dockerfile': build.dockerfile,
      if (build.args.isNotEmpty) 'buildargs': jsonEncode(build.args),
    };

    final _EngineResponse res;
    try {
      res = await _sendBytes(
        'POST',
        '/build?${_query(query)}',
        bytes: tar,
        contentType: 'application/x-tar',
        timeout: buildTimeout,
      );
    } on EngineError catch (e) {
      // Only reachable via the timeout below: same reasoning as pullImage's
      // own catch of the same thing.
      throw ImageBuildFailed(tag: tag, detail: e.body);
    }

    if (res.statusCode >= 400) {
      throw ImageBuildFailed(tag: tag, detail: res.text);
    }

    // Docker answers 200 and then reports failure inside the build's
    // progress stream, so the body has to be read even on success — the
    // exact trap pullImage already avoids, and for the same reason.
    final failure = _buildFailure(res.text);
    if (failure != null) {
      throw ImageBuildFailed(tag: tag, detail: failure);
    }
  }

  /// Reads a build's progress stream, returning null on success.
  ///
  /// On failure, the result carries both the error Docker reported and the
  /// `stream` output that led up to it — the output is what tells a caller
  /// which `RUN` step actually failed, not just that the build did.
  static String? _buildFailure(String body) {
    final output = StringBuffer();
    String? error;

    for (final line in body.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(trimmed);
      } on FormatException {
        continue;
      }
      if (decoded is! Map) continue;

      final stream = decoded['stream'];
      if (stream != null) output.write(stream);

      error ??= _errorIn(decoded);
    }

    if (error == null) return null;
    if (output.isEmpty) return error;
    return '$error\n\nBuild output:\n$output';
  }

  static String? _errorIn(Map<Object?, Object?> decoded) {
    final direct = decoded['error'];
    if (direct != null) return direct.toString();

    final detail = decoded['errorDetail'];
    if (detail is Map && detail['message'] != null) {
      return detail['message'].toString();
    }

    // A plain top-level `message` is how a build request Docker rejects
    // outright (a bad `dockerfile` query param, say) reports itself, distinct
    // from `error`/`errorDetail`, which come from inside the build itself.
    final message = decoded['message'];
    return message?.toString();
  }

  Future<_EngineResponse> _sendBytes(
    String method,
    String path, {
    required List<int> bytes,
    required String contentType,
    Duration? timeout,
  }) async {
    final budget = timeout ?? requestTimeout;
    final fullPath = '/$apiVersion$path';
    try {
      return await _sendBytesOnce(
        method,
        fullPath,
        bytes,
        contentType,
      ).timeout(budget);
    } on TimeoutException {
      throw EngineError(
        method: method,
        path: fullPath,
        statusCode: 0,
        body: 'Docker did not respond within ${_formatDuration(budget)}',
      );
    }
  }

  Future<_EngineResponse> _sendBytesOnce(
    String method,
    String fullPath,
    List<int> bytes,
    String contentType,
  ) async {
    final uri = Uri.parse('http://localhost$fullPath');
    final request = await _client.openUrl(method, uri);
    request.headers.set(HttpHeaders.contentTypeHeader, contentType);
    request.headers.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close();
    final out = <int>[];
    await response.forEach(out.addAll);
    return _EngineResponse(
      statusCode: response.statusCode,
      bytes: out,
      method: method,
      path: fullPath,
    );
  }

  static String _query(Map<String, String> params) => params.entries
      .map(
        (e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
      )
      .join('&');
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
