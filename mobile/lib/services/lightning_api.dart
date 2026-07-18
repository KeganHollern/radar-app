import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/lightning_models.dart';

final class LightningApiException implements Exception {
  const LightningApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  bool get indicatesUnavailable =>
      statusCode == 404 || statusCode == 501 || statusCode == 503;

  @override
  String toString() => message;
}

abstract interface class LightningDataSource {
  Future<LightningSnapshot> fetchLatest({LightningBounds? bounds});

  Stream<LightningUpdate> watchUpdates({
    LightningBounds? bounds,
    String? lastEventId,
  });

  void close();
}

final class LightningApi implements LightningDataSource {
  LightningApi({
    required String baseUrl,
    http.Client? client,
    Duration requestTimeout = const Duration(seconds: 12),
    Duration streamIdleTimeout = const Duration(seconds: 45),
  }) : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), ''),
       _client = client ?? http.Client(),
       _requestTimeout = requestTimeout,
       _streamIdleTimeout = streamIdleTimeout;

  final String baseUrl;
  final http.Client _client;
  final Duration _requestTimeout;
  final Duration _streamIdleTimeout;

  @override
  Future<LightningSnapshot> fetchLatest({LightningBounds? bounds}) async {
    final response = await _client
        .get(
          _uri('/api/v1/lightning/latest', bounds),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(_requestTimeout);
    _checkResponse(response.statusCode, response.body);
    try {
      return LightningSnapshot.fromJson(_decodeObject(response.body));
    } on FormatException catch (error) {
      throw LightningApiException(
        'Invalid lightning response: ${error.message}',
      );
    }
  }

  @override
  Stream<LightningUpdate> watchUpdates({
    LightningBounds? bounds,
    String? lastEventId,
  }) async* {
    final request = http.Request(
      'GET',
      _uri('/api/v1/lightning/updates', bounds),
    );
    request.headers.addAll(const {
      'Accept': 'text/event-stream',
      'Cache-Control': 'no-cache',
    });
    if (lastEventId != null && lastEventId.trim().isNotEmpty) {
      request.headers['Last-Event-ID'] = lastEventId;
    }
    final response = await _client.send(request).timeout(_requestTimeout);
    final responseBody = response.stream.timeout(
      _streamIdleTimeout,
      onTimeout: (sink) {
        sink.addError(
          const LightningApiException(
            'Lightning stream stopped responding; reconnecting',
          ),
        );
        sink.close();
      },
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await utf8.decoder.bind(responseBody).join();
      _checkResponse(response.statusCode, body);
    }

    var eventName = 'message';
    String? eventId;
    final data = StringBuffer();
    await for (final line
        in responseBody
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (data.isNotEmpty) {
          final update = _parseSseEvent(
            eventName: eventName,
            eventId: eventId,
            data: data.toString(),
          );
          if (update != null) yield update;
        }
        eventName = 'message';
        eventId = null;
        data.clear();
        continue;
      }
      if (line.startsWith(':')) continue;
      if (line.startsWith('event:')) {
        eventName = line.substring(6).trim();
      } else if (line.startsWith('id:')) {
        eventId = line.substring(3).trim();
      } else if (line.startsWith('data:')) {
        if (data.isNotEmpty) data.write('\n');
        data.write(line.substring(5).trimLeft());
      }
    }
  }

  LightningUpdate? _parseSseEvent({
    required String eventName,
    required String? eventId,
    required String data,
  }) {
    try {
      final event = LightningStreamEvent.fromSseName(eventName);
      final json = _decodeObject(data);
      final hasSnapshot =
          json.containsKey('data') ||
          json.containsKey('features') ||
          json.containsKey('strikes') ||
          json.containsKey('snapshot');
      return LightningUpdate(
        event: event,
        snapshot: hasSnapshot ? LightningSnapshot.fromJson(json) : null,
        id: eventId,
      );
    } on FormatException {
      // One malformed provider event must not tear down an otherwise healthy
      // long-lived stream. A later valid snapshot repairs client state.
      return null;
    }
  }

  Uri _uri(String path, LightningBounds? bounds) =>
      Uri.parse('$baseUrl$path').replace(
        queryParameters: bounds == null ? null : {'bbox': bounds.queryValue},
      );

  void _checkResponse(int statusCode, String body) {
    if (statusCode >= 200 && statusCode < 300) return;
    var message = 'Lightning service returned $statusCode';
    try {
      final decoded = _decodeObject(body);
      final error = decoded['error'];
      if (error is Map && error['message'] != null) {
        message = error['message'].toString();
      } else if (decoded['message'] != null) {
        message = decoded['message'].toString();
      }
    } catch (_) {
      // Keep the concise HTTP fallback for non-JSON error responses.
    }
    throw LightningApiException(message, statusCode: statusCode);
  }

  @override
  void close() => _client.close();
}

Map<String, dynamic> _decodeObject(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map) throw const FormatException('Expected a JSON object');
  return Map<String, dynamic>.from(decoded);
}
