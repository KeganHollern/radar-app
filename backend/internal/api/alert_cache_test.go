package api

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/KeganHollern/radar-app/backend/internal/cache"
	"github.com/KeganHollern/radar-app/backend/internal/config"
	"github.com/KeganHollern/radar-app/backend/internal/upstream"
)

type alertCacheTransport func(*http.Request) (*http.Response, error)

func (f alertCacheTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	return f(r)
}

func alertCacheServer(body *string) (*Server, *cache.Cache) {
	responseCache := cache.New(10, 1<<20)
	client := &http.Client{Transport: alertCacheTransport(func(r *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusOK,
			Status:     "200 OK",
			Header:     http.Header{"Content-Type": {"application/geo+json"}},
			Body:       io.NopCloser(strings.NewReader(*body)),
			Request:    r,
		}, nil
	})}
	return &Server{
		config: config.Config{
			NWSBaseURL:        "https://example.test",
			AlertTTL:          time.Minute,
			AlertZoneTTL:      24 * time.Hour,
			AggregateTokenKey: strings.Repeat("k", 32),
		},
		fetcher: upstream.NewFetcher(client, responseCache, "radar-test", 1<<20, time.Minute),
	}, responseCache
}

func TestAlertsRejectInvalidCollectionWithoutPoisoningCache(t *testing.T) {
	for _, invalid := range []string{
		`{"status":503,"title":"Service unavailable"}`,
		`{"type":"FeatureCollection"}`,
		`{"type":"FeatureCollection","features":null}`,
		`{"type":"FeatureCollection","features":[null]}`,
		`{"type":"FeatureCollection","features":[{"properties":{}}]}`,
	} {
		t.Run(invalid, func(t *testing.T) {
			body := invalid
			server, _ := alertCacheServer(&body)
			first := httptest.NewRecorder()
			server.alerts(first, httptest.NewRequest(http.MethodGet, "/api/v1/alerts", nil))
			if first.Code != http.StatusBadGateway {
				t.Fatalf("invalid upstream response returned %d: %s", first.Code, first.Body.String())
			}
			body = `{"type":"FeatureCollection","features":[]}`
			second := httptest.NewRecorder()
			server.alerts(second, httptest.NewRequest(http.MethodGet, "/api/v1/alerts", nil))
			if second.Code != http.StatusOK || strings.TrimSpace(second.Body.String()) != body {
				t.Fatalf("corrected collection remained unavailable: %d %s", second.Code, second.Body.String())
			}
		})
	}
}

func TestAlertsInvalidRefreshPreservesValidatedStaleCollection(t *testing.T) {
	body := `{"status":503,"title":"Service unavailable"}`
	server, responseCache := alertCacheServer(&body)
	target, err := server.alertsURL(nil)
	if err != nil {
		t.Fatal(err)
	}
	checkedAt := time.Now().UTC().Add(-2 * time.Minute)
	responseCache.Put("alerts:"+server.privateScopeKey(target), cache.Value{
		Body:       []byte(`{"type":"FeatureCollection","features":[]}`),
		FetchedAt:  checkedAt,
		CheckedAt:  checkedAt,
		ExpiresAt:  time.Now().Add(-time.Minute),
		StaleUntil: time.Now().Add(time.Minute),
	})
	response := httptest.NewRecorder()
	server.alerts(response, httptest.NewRequest(http.MethodGet, "/api/v1/alerts", nil))
	if response.Code != http.StatusOK || response.Header().Get("X-Radar-Cache") != string(cache.Stale) {
		t.Fatalf("validated stale alerts lost: %d %v %s", response.Code, response.Header(), response.Body.String())
	}
	if response.Header().Get("X-Data-Checked-At") != checkedAt.Format(time.RFC3339Nano) {
		t.Fatalf("failed refresh advanced alert provenance: %v", response.Header())
	}
}

func TestZoneRejectsInvalidBodyWithoutPoisoningDailyCache(t *testing.T) {
	body := `{"status":503,"title":"Service unavailable"}`
	server, _ := alertCacheServer(&body)
	request := zoneRequest{key: "forecast/TXZ001", target: "https://example.test/zones/forecast/TXZ001"}
	if _, err := server.fetchZone(context.Background(), request); err == nil {
		t.Fatal("invalid zone response was accepted")
	}
	body = geoJSONPolygon
	polygons, err := server.fetchZone(context.Background(), request)
	if err != nil || len(polygons) != 1 {
		t.Fatalf("corrected zone remained unavailable: polygons=%v error=%v", polygons, err)
	}
}

func TestZoneInvalidRefreshPreservesValidatedStaleShape(t *testing.T) {
	body := `{"type":"Feature","geometry":null}`
	server, responseCache := alertCacheServer(&body)
	request := zoneRequest{key: "forecast/TXZ001", target: "https://example.test/zones/forecast/TXZ001"}
	responseCache.Put("alert-zone:"+request.key, cache.Value{
		Body:       []byte(geoJSONPolygon),
		ExpiresAt:  time.Now().Add(-time.Minute),
		StaleUntil: time.Now().Add(time.Minute),
	})
	polygons, err := server.fetchZone(context.Background(), request)
	if err != nil || len(polygons) != 1 {
		t.Fatalf("validated stale shape lost: polygons=%v error=%v", polygons, err)
	}
}
