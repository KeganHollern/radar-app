import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:radar_mobile/services/http_event_stream.dart';

void main() {
  test('cancellation closes a silent response without another event', () async {
    final client = _Client();
    var bodyCancelled = false;
    final body = StreamController<List<int>>(
      onCancel: () => bodyCancelled = true,
    );
    final subscription = _open(client).listen((_) {});
    client.response.complete(http.StreamedResponse(body.stream, 200));
    await pumpEventQueue();

    await subscription.cancel();
    expect(bodyCancelled, isTrue);
    await body.close();
  });

  test(
    'cancellation aborts pending headers and discards a late response',
    () async {
      final client = _Client();
      final subscription = _open(client).listen((_) {});
      await pumpEventQueue();
      var aborted = false;
      unawaited(
        (client.request! as http.Abortable).abortTrigger!.then(
          (_) => aborted = true,
        ),
      );

      await subscription.cancel();
      await pumpEventQueue();
      expect(aborted, isTrue);

      var bodyCancelled = false;
      final body = StreamController<List<int>>(
        onCancel: () => bodyCancelled = true,
      );
      client.response.complete(http.StreamedResponse(body.stream, 200));
      await pumpEventQueue();
      expect(bodyCancelled, isTrue);
      await body.close();
    },
  );

  test(
    'header timeout aborts and releases a response arriving afterward',
    () async {
      final client = _Client();
      await expectLater(
        _open(client, timeout: const Duration(milliseconds: 10)).drain<void>(),
        throwsA(isA<TimeoutException>()),
      );

      var bodyCancelled = false;
      final body = StreamController<List<int>>(
        onCancel: () => bodyCancelled = true,
      );
      client.response.complete(http.StreamedResponse(body.stream, 200));
      await pumpEventQueue();
      expect(bodyCancelled, isTrue);
      await body.close();
    },
  );

  test('an unlistened stream does not start a request', () async {
    final client = _Client();
    _open(client);
    await pumpEventQueue();
    expect(client.request, isNull);
  });
}

Stream<List<int>> _open(
  _Client client, {
  Duration timeout = const Duration(seconds: 12),
}) => openHttpEventStream(
  client: client,
  uri: Uri.parse('https://radar.test/updates'),
  headers: const {'Accept': 'text/event-stream'},
  requestTimeout: timeout,
  parse: (response) => response.stream,
);

final class _Client extends http.BaseClient {
  http.BaseRequest? request;
  final response = Completer<http.StreamedResponse>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    this.request = request;
    return response.future;
  }
}
