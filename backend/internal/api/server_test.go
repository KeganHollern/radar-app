package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"github.com/KeganHollern/radar-app/backend/internal/cache"
	"github.com/KeganHollern/radar-app/backend/internal/config"
	"github.com/KeganHollern/radar-app/backend/internal/upstream"
)

func TestAlertsURLIncludesActiveUpdates(t *testing.T) {
	s := &Server{config: config.Config{NWSBaseURL: "https://api.weather.gov"}}
	target, err := s.alertsURL(url.Values{"area": {"tx"}})
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := url.Parse(target)
	if err != nil {
		t.Fatal(err)
	}
	query := parsed.Query()
	if query.Get("status") != "actual" || query.Get("area") != "TX" {
		t.Fatalf("unexpected query: %s", parsed.RawQuery)
	}
	if _, filtered := query["message_type"]; filtered {
		t.Fatal("active alerts must not filter message_type; Update messages are active alerts")
	}
}

func TestWriteCachedHonorsETag(t *testing.T) {
	body := []byte("same response")
	first := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	result := upstream.Result{Value: cache.Value{FetchedAt: time.Unix(100, 0)}, State: cache.Hit}
	writeCached(first, request, http.StatusOK, body, "text/plain", result, "public, max-age=10")
	if first.Code != http.StatusOK || first.Header().Get("ETag") == "" {
		t.Fatalf("unexpected initial response: %d %#v", first.Code, first.Header())
	}

	second := httptest.NewRecorder()
	request = httptest.NewRequest(http.MethodGet, "/", nil)
	request.Header.Set("If-None-Match", first.Header().Get("ETag"))
	writeCached(second, request, http.StatusOK, body, "text/plain", result, "public, max-age=10")
	if second.Code != http.StatusNotModified || second.Body.Len() != 0 {
		t.Fatalf("unexpected conditional response: %d %q", second.Code, second.Body.String())
	}
}

func TestNormalizeStationsAddsCapabilitiesAndDeduplicates(t *testing.T) {
	input := []byte(`{"type":"FeatureCollection","features":[
		{"type":"Feature","geometry":{"type":"Point","coordinates":[-97,32]},"properties":{"rda_id":"KFWS","name":"Fort Worth","wfo_id":"FWD","elevmeter":200}},
		{"type":"Feature","geometry":{"type":"Point","coordinates":[-97,32]},"properties":{"rda_id":"KFWS","name":"duplicate"}},
		{"type":"Feature","geometry":{"type":"Point","coordinates":[-97,32]},"properties":{"rda_id":"TDFW","name":"TDWR"}}
	]}`)
	body, err := normalizeStations(input, []string{"0.5", "0.9"}, []string{"0.5"})
	if err != nil {
		t.Fatal(err)
	}
	var collection featureCollection
	if err := json.Unmarshal(body, &collection); err != nil {
		t.Fatal(err)
	}
	if len(collection.Features) != 1 {
		t.Fatalf("got %d features, want 1", len(collection.Features))
	}
	properties := collection.Features[0]["properties"].(map[string]any)
	if properties["supports_velocity"] != true || properties["supports_reflectivity"] != true {
		t.Fatalf("missing capabilities: %#v", properties)
	}
	if got := len(properties["elevations"].([]any)); got != 2 {
		t.Fatalf("got %d elevations", got)
	}
}

func TestDecorateAlerts(t *testing.T) {
	body, err := decorateAlerts([]byte(`{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"event":"Tornado Warning","severity":"Extreme"}}]}`))
	if err != nil {
		t.Fatal(err)
	}
	var collection featureCollection
	if err := json.Unmarshal(body, &collection); err != nil {
		t.Fatal(err)
	}
	properties := collection.Features[0]["properties"].(map[string]any)
	if properties["radarCategory"] != "tornado" || properties["radarColor"] != "#D14D41" {
		t.Fatalf("unexpected decoration: %#v", properties)
	}
}
