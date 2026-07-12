package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/KeganHollern/radar-app/backend/internal/cache"
	"github.com/KeganHollern/radar-app/backend/internal/config"
	"github.com/KeganHollern/radar-app/backend/internal/upstream"
)

func TestEnrichAlertsCombinesTrustedZonesAndDegradesPartially(t *testing.T) {
	var forecastCalls atomic.Int32
	var countyCalls atomic.Int32
	var failedCalls atomic.Int32
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/geo+json")
		switch r.URL.Path {
		case "/zones/forecast/TXZ001":
			forecastCalls.Add(1)
			_, _ = fmt.Fprint(w, geoJSONPolygon)
		case "/zones/county/TXC001":
			countyCalls.Add(1)
			_, _ = fmt.Fprint(w, geoJSONMultiPolygon)
		case "/zones/fire/TXZ999":
			failedCalls.Add(1)
			http.Error(w, "temporarily unavailable", http.StatusServiceUnavailable)
		default:
			http.NotFound(w, r)
		}
	}))
	defer provider.Close()

	server := zoneTestAPI(provider, 8, 4)
	body := alertCollection(
		provider.URL+"/zones/forecast/TXZ001",
		provider.URL+"/zones/county/TXC001",
		provider.URL+"/zones/fire/TXZ999",
		"https://api.weather.gov.evil.example/zones/forecast/EVIL01",
	)
	result, err := server.enrichAlerts(context.Background(), body)
	if err != nil {
		t.Fatal(err)
	}
	feature, properties, geometry := decodeSingleAlert(t, result)
	if feature["geometry"] == nil || geometry["type"] != "MultiPolygon" {
		t.Fatalf("unexpected geometry: %#v", feature["geometry"])
	}
	coordinates, ok := geometry["coordinates"].([]any)
	if !ok || len(coordinates) != 2 {
		t.Fatalf("combined polygon count = %#v, want 2", geometry["coordinates"])
	}
	if properties["radarGeometrySource"] != "affectedZones" || properties["radarGeometryZoneCount"] != float64(2) {
		t.Fatalf("missing geometry provenance: %#v", properties)
	}
	if properties["radarGeometryZonesRequested"] != float64(3) || properties["radarGeometryZonesResolved"] != float64(2) || properties["radarGeometryPartial"] != true {
		t.Fatalf("missing partial geometry counts: %#v", properties)
	}
	if forecastCalls.Load() != 1 || countyCalls.Load() != 1 || failedCalls.Load() != 1 {
		t.Fatalf("unexpected provider calls: forecast=%d county=%d failed=%d", forecastCalls.Load(), countyCalls.Load(), failedCalls.Load())
	}

	// Successful zone shapes are shared through the normal bounded response
	// cache; the failed zone may be retried without suppressing cached shapes.
	if _, err := server.enrichAlerts(context.Background(), body); err != nil {
		t.Fatal(err)
	}
	if forecastCalls.Load() != 1 || countyCalls.Load() != 1 {
		t.Fatalf("successful zones were not cached: forecast=%d county=%d", forecastCalls.Load(), countyCalls.Load())
	}
}

func TestEnrichAlertsBoundsZoneWork(t *testing.T) {
	var calls atomic.Int32
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.Header().Set("Content-Type", "application/geo+json")
		_, _ = fmt.Fprint(w, geoJSONPolygon)
	}))
	defer provider.Close()

	server := zoneTestAPI(provider, 1, 1)
	result, err := server.enrichAlerts(context.Background(), alertCollection(
		provider.URL+"/zones/forecast/TXZ001",
		provider.URL+"/zones/forecast/TXZ002",
	))
	if err != nil {
		t.Fatal(err)
	}
	_, properties, geometry := decodeSingleAlert(t, result)
	if calls.Load() != 1 {
		t.Fatalf("zone requests = %d, want configured maximum 1", calls.Load())
	}
	if geometry["type"] != "MultiPolygon" || properties["radarGeometryZoneCount"] != float64(1) {
		t.Fatalf("expected partial zone-derived geometry: %#v %#v", geometry, properties)
	}
	if properties["radarGeometryZonesRequested"] != float64(2) || properties["radarGeometryZonesResolved"] != float64(1) || properties["radarGeometryPartial"] != true {
		t.Fatalf("first response was not marked partial: %#v", properties)
	}

	result, err = server.enrichAlerts(context.Background(), alertCollection(
		provider.URL+"/zones/forecast/TXZ001",
		provider.URL+"/zones/forecast/TXZ002",
	))
	if err != nil {
		t.Fatal(err)
	}
	_, properties, geometry = decodeSingleAlert(t, result)
	if calls.Load() != 2 {
		t.Fatalf("second enrichment did not advance beyond cached cap: calls=%d", calls.Load())
	}
	if len(geometry["coordinates"].([]any)) != 2 || properties["radarGeometryZonesResolved"] != float64(2) || properties["radarGeometryPartial"] != false {
		t.Fatalf("second response did not complete geometry: %#v %#v", geometry, properties)
	}
}

func TestEnrichAlertsFailedZoneDoesNotStarveLaterMisses(t *testing.T) {
	var failedCalls atomic.Int32
	var successCalls atomic.Int32
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/zones/forecast/TXZ001":
			failedCalls.Add(1)
			http.Error(w, "down", http.StatusServiceUnavailable)
		case "/zones/forecast/TXZ002":
			successCalls.Add(1)
			w.Header().Set("Content-Type", "application/geo+json")
			_, _ = fmt.Fprint(w, geoJSONPolygon)
		default:
			http.NotFound(w, r)
		}
	}))
	defer provider.Close()

	server := zoneTestAPI(provider, 1, 1)
	body := alertCollection(provider.URL+"/zones/forecast/TXZ001", provider.URL+"/zones/forecast/TXZ002")
	first, err := server.enrichAlerts(context.Background(), body)
	if err != nil {
		t.Fatal(err)
	}
	feature, properties, _ := decodeSingleAlert(t, first)
	if feature["geometry"] != nil || properties["radarGeometryZonesRequested"] != float64(2) || properties["radarGeometryZonesResolved"] != float64(0) || properties["radarGeometryPartial"] != true {
		t.Fatalf("null partial geometry lacks counts: %#v", feature)
	}

	second, err := server.enrichAlerts(context.Background(), body)
	if err != nil {
		t.Fatal(err)
	}
	_, properties, geometry := decodeSingleAlert(t, second)
	if failedCalls.Load() != 1 || successCalls.Load() != 1 {
		t.Fatalf("negative cooldown did not advance: failed=%d success=%d", failedCalls.Load(), successCalls.Load())
	}
	if geometry["type"] != "MultiPolygon" || properties["radarGeometryZonesResolved"] != float64(1) || properties["radarGeometryPartial"] != true {
		t.Fatalf("later successful zone was not included: %#v %#v", geometry, properties)
	}
}

func TestEnrichAlertsRejectsUntrustedZoneURLs(t *testing.T) {
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("untrusted URL must not be requested")
	}))
	defer provider.Close()

	server := zoneTestAPI(provider, 4, 2)
	result, err := server.enrichAlerts(context.Background(), alertCollection(
		"https://api.weather.gov.evil.example/zones/forecast/TXZ001",
		provider.URL+"/zones/forecast/../county/TXC001",
	))
	if err != nil {
		t.Fatal(err)
	}
	feature, properties, _ := decodeSingleAlert(t, result)
	if feature["geometry"] != nil || properties["radarGeometrySource"] != nil {
		t.Fatalf("untrusted zones unexpectedly produced geometry: %#v", feature)
	}
}

func zoneTestAPI(provider *httptest.Server, maxFetches, workers int) *Server {
	c := config.Config{
		NWSBaseURL:       provider.URL,
		AlertZoneTTL:     time.Hour,
		AlertZoneTimeout: 2 * time.Second,
		AlertZoneFailTTL: time.Minute,
		AlertZoneMax:     maxFetches,
		AlertZoneWorkers: workers,
		StaleTTL:         time.Minute,
	}
	fetcher := upstream.NewFetcher(provider.Client(), cache.New(100, 1<<20), "radar-test", 1<<20, time.Minute)
	return &Server{config: c, fetcher: fetcher}
}

func alertCollection(zones ...string) []byte {
	body, _ := json.Marshal(map[string]any{
		"type": "FeatureCollection",
		"features": []any{map[string]any{
			"type":     "Feature",
			"geometry": nil,
			"properties": map[string]any{
				"event":         "Winter Storm Warning",
				"severity":      "Severe",
				"urgency":       "Immediate",
				"affectedZones": zones,
			},
		}},
	})
	return body
}

func decodeSingleAlert(t *testing.T, body []byte) (map[string]any, map[string]any, map[string]any) {
	t.Helper()
	var collection featureCollection
	if err := json.Unmarshal(body, &collection); err != nil {
		t.Fatal(err)
	}
	feature := collection.Features[0]
	properties := feature["properties"].(map[string]any)
	geometry, _ := feature["geometry"].(map[string]any)
	return feature, properties, geometry
}

const geoJSONPolygon = `{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-100,30],[-99,30],[-99,31],[-100,30]]]},"properties":{}}`

const geoJSONMultiPolygon = `{"type":"Feature","geometry":{"type":"MultiPolygon","coordinates":[[[[-98,32],[-97,32],[-97,33],[-98,32]]]]},"properties":{}}`
