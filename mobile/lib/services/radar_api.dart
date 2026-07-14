import 'dart:convert';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import '../models/radar_models.dart';

final class RadarApiException implements Exception {
  const RadarApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

final class RadarApi {
  RadarApi({required String baseUrl, http.Client? client})
    : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), ''),
      _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;
  String? _alertsEtag;
  List<WeatherAlert> _cachedAlerts = const [];

  Future<List<RadarStation>> fetchStations() async {
    final json = await _getObject('/api/v1/stations');
    final candidates = _extractList(json, const [
      'features',
      'stations',
      'data',
    ]);
    return candidates
        .whereType<Map>()
        .map((item) => RadarStation.fromJson(Map<String, dynamic>.from(item)))
        .where(
          (station) =>
              station.id.isNotEmpty &&
              station.latitude.abs() <= 90 &&
              station.longitude.abs() <= 180,
        )
        .toList(growable: false);
  }

  Future<AlertsResult> fetchAlerts() async {
    const path = '/api/v1/alerts';
    final headers = <String, String>{'Accept': 'application/json'};
    final previousEtag = _alertsEtag;
    if (previousEtag != null) headers['If-None-Match'] = previousEtag;
    final response = await _client
        .get(_uri(path), headers: headers)
        .timeout(const Duration(seconds: 12));
    final cacheStatus = _headerValue(response.headers, 'x-radar-cache') ?? '';
    final stale = cacheStatus.toUpperCase().contains('STALE');
    if (response.statusCode == 304) {
      return AlertsResult(alerts: _cachedAlerts, stale: stale, changed: false);
    }
    _checkResponse(response);
    final responseEtag = _headerValue(response.headers, 'etag');
    if (previousEtag != null && responseEtag == previousEtag) {
      return AlertsResult(alerts: _cachedAlerts, stale: stale, changed: false);
    }

    // National alert collections can contain hundreds of detailed polygons.
    // Decode and normalize them away from Flutter's UI isolate.
    final alerts = await Isolate.run(() => _parseAlerts(response.body));
    _cachedAlerts = alerts;
    _alertsEtag = responseEtag;
    return AlertsResult(alerts: alerts, stale: stale, changed: true);
  }

  Future<RadarSnapshot> fetchLatest({
    required RadarMode mode,
    RadarStation? station,
    String? elevation,
  }) async {
    final query = <String, String>{'product': mode.apiValue};
    if (station != null) query['station'] = station.id;
    if (elevation != null && elevation.isNotEmpty) {
      query['elevation'] = elevation;
    }
    final uri = _uri('/api/v1/radar/latest', query);
    final response = await _client
        .get(uri, headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 12));
    _checkResponse(response);
    return RadarSnapshot.fromJson(decodeObject(response.body));
  }

  Stream<RadarUpdate> watchUpdates({
    required RadarMode mode,
    RadarStation? station,
    String? elevation,
  }) async* {
    final query = <String, String>{'product': mode.apiValue};
    if (station != null) query['station'] = station.id;
    if (elevation != null && elevation.isNotEmpty) {
      query['elevation'] = elevation;
    }
    final request = http.Request('GET', _uri('/api/v1/updates', query));
    request.headers.addAll(const {
      'Accept': 'text/event-stream',
      'Cache-Control': 'no-cache',
    });
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 12));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.stream.bytesToString();
      throw RadarApiException(
        body.isEmpty
            ? 'Live update stream returned ${response.statusCode}'
            : body,
        statusCode: response.statusCode,
      );
    }

    String event = 'message';
    final data = StringBuffer();
    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (data.isNotEmpty) {
          final decoded = jsonDecode(data.toString());
          if (decoded is Map) {
            final object = Map<String, dynamic>.from(decoded);
            final radar = object['radar'];
            yield RadarUpdate(
              event: event,
              snapshot: radar is Map
                  ? RadarSnapshot.fromJson(Map<String, dynamic>.from(radar))
                  : null,
              radarChanged: object['radarChanged'] == true,
              refreshAlerts: object['refreshAlerts'] == true,
            );
          }
        }
        event = 'message';
        data.clear();
        continue;
      }
      if (line.startsWith(':')) continue;
      if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        if (data.isNotEmpty) data.write('\n');
        data.write(line.substring(5).trimLeft());
      }
    }
  }

  String tileTemplate({
    required RadarMode mode,
    required RadarSnapshot snapshot,
    RadarStation? station,
    String? elevation,
  }) {
    final effectiveStation = station;
    final effectiveElevation = mode.requiresStation ? elevation : null;
    var template = snapshot.tileTemplate;
    if (template == null || template.isEmpty) {
      final stationPath = Uri.encodeComponent(effectiveStation?.id ?? '_');
      final elevationPath = Uri.encodeComponent(effectiveElevation ?? '_');
      template =
          '$baseUrl/api/v1/radar/tiles/${mode.apiValue}/$stationPath/'
          '$elevationPath/{z}/{x}/{y}.png';
    } else if (template.startsWith('/')) {
      template = '$baseUrl$template';
    } else if (!template.startsWith('http://') &&
        !template.startsWith('https://')) {
      template = '$baseUrl/$template';
    }

    template = template
        .replaceAll('{product}', mode.apiValue)
        .replaceAll(
          '{station}',
          Uri.encodeComponent(effectiveStation?.id ?? '_'),
        )
        .replaceAll(
          '{elevation}',
          Uri.encodeComponent(effectiveElevation ?? '_'),
        );
    final separator = template.contains('?') ? '&' : '?';
    return '$template${separator}v=${Uri.encodeQueryComponent(snapshot.version)}';
  }

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Future<Map<String, dynamic>> _getObject(String path) async {
    final response = await _client
        .get(_uri(path), headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 12));
    _checkResponse(response);
    try {
      return decodeObject(response.body);
    } on FormatException catch (error) {
      throw RadarApiException('Invalid response from $path: ${error.message}');
    }
  }

  void _checkResponse(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    var message = 'Radar service returned ${response.statusCode}';
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map && error['message'] != null) {
          message = error['message'].toString();
        } else {
          message = (error ?? decoded['message'] ?? message).toString();
        }
      }
    } catch (_) {
      // Keep the concise HTTP fallback when the error body is not JSON.
    }
    throw RadarApiException(message, statusCode: response.statusCode);
  }

  void close() => _client.close();
}

final class RadarUpdate {
  const RadarUpdate({
    required this.event,
    required this.snapshot,
    required this.radarChanged,
    required this.refreshAlerts,
  });

  final String event;
  final RadarSnapshot? snapshot;
  final bool radarChanged;
  final bool refreshAlerts;
}

final class AlertsResult {
  const AlertsResult({
    required this.alerts,
    required this.stale,
    this.changed = true,
  });

  final List<WeatherAlert> alerts;
  final bool stale;
  final bool changed;
}

List<WeatherAlert> _parseAlerts(String body) {
  final json = decodeObject(body);
  final candidates = _extractList(json, const ['features', 'alerts', 'data']);
  return candidates
      .whereType<Map>()
      .map((item) {
        final raw = Map<String, dynamic>.from(item);
        if (raw['type'] == 'Feature') return WeatherAlert.fromFeature(raw);
        return WeatherAlert.fromFeature({
          'type': 'Feature',
          'id': raw['id'],
          'properties': raw,
          'geometry': raw['geometry'],
        });
      })
      .where((alert) => alert.id.isNotEmpty)
      .toList(growable: false);
}

List<dynamic> _extractList(
  Map<String, dynamic> object,
  List<String> candidateKeys,
) {
  for (final key in candidateKeys) {
    final value = object[key];
    if (value is List) return value;
    if (value is Map) {
      final nested = Map<String, dynamic>.from(value);
      for (final nestedKey in candidateKeys) {
        final list = nested[nestedKey];
        if (list is List) return list;
      }
    }
  }
  return const [];
}

String? _headerValue(Map<String, String> headers, String name) {
  final normalizedName = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == normalizedName) return entry.value;
  }
  return null;
}
