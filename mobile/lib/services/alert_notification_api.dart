import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/alert_notification_models.dart';
import '../models/radar_models.dart';

final class AlertNotificationPoint {
  const AlertNotificationPoint({
    required this.latitude,
    required this.longitude,
    required this.observedAt,
    this.accuracyMeters,
  });

  final double latitude;
  final double longitude;
  final DateTime observedAt;
  final double? accuracyMeters;
}

final class AlertNotificationApiException implements Exception {
  const AlertNotificationApiException(this.message, {this.transient = false});

  final String message;
  final bool transient;

  @override
  String toString() => message;
}

abstract interface class AlertNotificationApi {
  Future<AlertNotificationFetchResult> fetchActiveAlerts({
    required AlertNotificationScope scope,
    AlertNotificationPoint? point,
    bool bypassCache = false,
  });

  Future<void> acknowledge(AlertNotificationFetchResult result);
}

final class AlertNotificationFetchResult {
  const AlertNotificationFetchResult({
    required this.alerts,
    this.notModified = false,
    this.requestState,
  });

  const AlertNotificationFetchResult.notModified()
    : alerts = const [],
      notModified = true,
      requestState = null;

  final List<WeatherAlert> alerts;
  final bool notModified;
  final AlertNotificationRequestState? requestState;
}

final class AlertNotificationRequestState {
  const AlertNotificationRequestState({required this.etag});

  final String? etag;
}

abstract interface class AlertNotificationRequestStateStore {
  Future<AlertNotificationRequestState?> load();

  Future<void> save(AlertNotificationRequestState state);
}

final class SharedPreferencesAlertNotificationRequestStateStore
    implements AlertNotificationRequestStateStore {
  SharedPreferencesAlertNotificationRequestStateStore({
    SharedPreferencesAsync? preferences,
  }) : _preferences = preferences ?? SharedPreferencesAsync();

  static const _key = 'alerts.notifications.http_state.v1';
  final SharedPreferencesAsync _preferences;

  @override
  Future<AlertNotificationRequestState?> load() async {
    try {
      final source = await _preferences.getString(_key);
      if (source == null) return null;
      final decoded = jsonDecode(source);
      if (decoded is! Map) return null;
      final etag = decoded['etag']?.toString();
      if (etag == null || etag.isEmpty) return null;
      return AlertNotificationRequestState(etag: etag);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(AlertNotificationRequestState state) async {
    await _preferences.setString(_key, jsonEncode({'etag': state.etag}));
  }
}

final class HttpAlertNotificationApi implements AlertNotificationApi {
  HttpAlertNotificationApi({
    required String baseUrl,
    http.Client? client,
    AlertNotificationRequestStateStore? requestStateStore,
  }) : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), ''),
       _client = client ?? http.Client(),
       _requestStateStore = requestStateStore;

  final String baseUrl;
  final http.Client _client;
  final AlertNotificationRequestStateStore? _requestStateStore;

  @override
  Future<AlertNotificationFetchResult> fetchActiveAlerts({
    required AlertNotificationScope scope,
    AlertNotificationPoint? point,
    bool bypassCache = false,
  }) async {
    if (scope == AlertNotificationScope.nearby && point == null) {
      throw const AlertNotificationApiException(
        'A location is required for nearby alerts.',
      );
    }
    final query = <String, String>{};
    if (scope == AlertNotificationScope.nearby) {
      query['point'] = [
        point!.latitude.toStringAsFixed(3),
        point.longitude.toStringAsFixed(3),
      ].join(',');
    }
    final uri = Uri.parse(
      '$baseUrl/api/v1/alerts',
    ).replace(queryParameters: query.isEmpty ? null : query);
    final headers = <String, String>{'Accept': 'application/geo+json'};
    final stateStore = _requestStateStore;
    var sentConditionalValidator = false;
    if (scope == AlertNotificationScope.nationwide &&
        !bypassCache &&
        stateStore != null) {
      final previous = await stateStore.load();
      if (previous?.etag != null && previous!.etag!.isNotEmpty) {
        headers['If-None-Match'] = previous.etag!;
        sentConditionalValidator = true;
      }
    }

    http.Response response;
    try {
      response = await _client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 20));
    } catch (error) {
      throw AlertNotificationApiException(
        'Unable to check weather alerts: $error',
        transient: true,
      );
    }
    if (response.statusCode == 304) {
      if (!sentConditionalValidator) {
        throw const AlertNotificationApiException(
          'Weather alert service returned an unexpected empty response.',
          transient: true,
        );
      }
      return const AlertNotificationFetchResult.notModified();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AlertNotificationApiException(
        'Weather alert service returned ${response.statusCode}.',
        transient: response.statusCode == 429 || response.statusCode >= 500,
      );
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) throw const FormatException('Expected an object');
      final features = decoded['features'];
      if (features is! List) {
        throw const FormatException('Expected a feature collection');
      }
      final alerts = features
          .whereType<Map>()
          .map(
            (feature) =>
                WeatherAlert.fromFeature(Map<String, dynamic>.from(feature)),
          )
          .where((alert) => alert.id.isNotEmpty)
          .toList(growable: false);
      return AlertNotificationFetchResult(
        alerts: alerts,
        requestState:
            stateStore == null || scope != AlertNotificationScope.nationwide
            ? null
            : AlertNotificationRequestState(etag: response.headers['etag']),
      );
    } catch (error) {
      throw AlertNotificationApiException(
        'Invalid weather alert response: $error',
        transient: true,
      );
    }
  }

  @override
  Future<void> acknowledge(AlertNotificationFetchResult result) async {
    final stateStore = _requestStateStore;
    final state = result.requestState;
    if (stateStore == null || state == null || result.notModified) return;
    try {
      await stateStore.save(state);
    } catch (_) {
      // Conditional requests are an optimization; a preference-store issue
      // must not turn a completed weather check into a failed worker.
    }
  }

  void close() => _client.close();
}
