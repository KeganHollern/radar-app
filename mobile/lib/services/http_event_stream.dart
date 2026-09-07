import 'dart:async';

import 'package:http/http.dart' as http;

/// Opens a cancellable HTTP stream without waiting for its next event to stop.
/// The request starts on listen; cancellation also aborts pending headers and
/// discards late responses from clients that do not implement Abortable.
Stream<T> openHttpEventStream<T>({
  required http.Client client,
  required Uri uri,
  required Map<String, String> headers,
  required Duration requestTimeout,
  required Stream<T> Function(http.StreamedResponse response) parse,
}) {
  final abort = Completer<void>();
  StreamSubscription<T>? subscription;
  Timer? timeout;
  var stopped = false;
  late final StreamController<T> controller;

  void abortRequest() {
    if (!abort.isCompleted) abort.complete();
  }

  void fail(Object error, StackTrace stackTrace) {
    if (stopped) return;
    stopped = true;
    timeout?.cancel();
    abortRequest();
    controller.addError(error, stackTrace);
    unawaited(controller.close());
  }

  controller = StreamController<T>(
    onListen: () {
      final request = http.AbortableRequest(
        'GET',
        uri,
        abortTrigger: abort.future,
      );
      request.headers.addAll(headers);
      timeout = Timer(requestTimeout, () {
        fail(
          TimeoutException('Live update request timed out', requestTimeout),
          StackTrace.current,
        );
      });
      unawaited(
        Future.sync(() => client.send(request)).then(
          (response) async {
            timeout?.cancel();
            if (stopped) {
              // Some injected/custom clients ignore the abort trigger. Consume the
              // response subscription only to cancel it and release its connection.
              await response.stream
                  .listen((_) {}, onError: (Object _) {})
                  .cancel();
              return;
            }
            try {
              subscription = parse(response).listen(
                controller.add,
                onError: controller.addError,
                onDone: controller.close,
              );
              if (controller.isPaused) subscription!.pause();
            } catch (error, stackTrace) {
              fail(error, stackTrace);
              await response.stream
                  .listen((_) {}, onError: (Object _) {})
                  .cancel();
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            fail(error, stackTrace);
          },
        ),
      );
    },
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
    onCancel: () {
      stopped = true;
      timeout?.cancel();
      abortRequest();
      return subscription?.cancel();
    },
  );
  return controller.stream;
}
