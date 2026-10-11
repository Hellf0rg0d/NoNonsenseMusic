// An HTTP client that answers from a table of routes, and an in-memory WebSocket link, for tests that run without a
// server.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/live_socket.dart';

/// Answers each request through [answer] (method, path and decoded body), recording what was asked as "METHOD /path".
class FakeServer extends http.BaseClient {
  FakeServer(this.answer);
  final Future<(int, Object?)> Function(String method, String path, Object? body) answer;
  final asked = <String>[];

  int count(String request) => asked.where((a) => a == request).length;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final text = request is http.Request ? request.body : '';
    final key = '${request.method} ${request.url.path}';
    asked.add(key);
    final (status, body) = await answer(request.method, request.url.path, text.isEmpty ? null : jsonDecode(text));
    return http.StreamedResponse(Stream.value(utf8.encode(body == null ? '' : jsonEncode(body))), status,
        headers: {'content-type': 'application/json'}, request: request);
  }
}

/// Points the app's API at [server] as a signed-in user.
void useServer(FakeServer server) {
  Api.base = 'http://server.test';
  Api.client = server;
  Api.token = 'test-token';
}

/// A WebSocket link the test drives: [push] is a message from the server, [sent] what the app sent.
class FakeLink implements SocketLink {
  final _in = StreamController<String>();
  final sent = <String>[];
  bool closed = false;

  @override
  Stream<String> get messages => _in.stream;
  @override
  void send(String text) => sent.add(text);
  @override
  void close() {
    closed = true;
    if (!_in.isClosed) _in.close();
  }

  void push(String text) => _in.add(text);
}
