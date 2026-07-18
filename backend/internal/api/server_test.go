package api

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
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
	result := upstream.Result{Value: cache.Value{
		FetchedAt: time.Unix(100, 0),
		CheckedAt: time.Unix(120, 0),
	}, State: cache.Hit}
	writeCached(first, request, http.StatusOK, body, "text/plain", result, "public, max-age=10")
	if first.Code != http.StatusOK || first.Header().Get("ETag") == "" {
		t.Fatalf("unexpected initial response: %d %#v", first.Code, first.Header())
	}
	if got := first.Header().Get("X-Data-Checked-At"); got != time.Unix(120, 0).UTC().Format(time.RFC3339Nano) {
		t.Fatalf("X-Data-Checked-At = %q", got)
	}

	etag := first.Header().Get("ETag")
	tests := []struct {
		name       string
		header     string
		wantStatus int
	}{
		{name: "strong", header: etag, wantStatus: http.StatusNotModified},
		{name: "cloudflare weak", header: "W/" + etag, wantStatus: http.StatusNotModified},
		{name: "list", header: `"other", W/` + etag, wantStatus: http.StatusNotModified},
		{name: "wildcard", header: "*", wantStatus: http.StatusNotModified},
		{name: "different", header: `W/"different"`, wantStatus: http.StatusOK},
		{name: "malformed", header: strings.Trim(etag, `"`), wantStatus: http.StatusOK},
		{name: "empty", wantStatus: http.StatusOK},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			response := httptest.NewRecorder()
			request := httptest.NewRequest(http.MethodGet, "/", nil)
			request.Header.Set("If-None-Match", test.header)
			writeCached(response, request, http.StatusOK, body, "text/plain", result, "public, max-age=10")
			if response.Code != test.wantStatus {
				t.Fatalf("status = %d, want %d", response.Code, test.wantStatus)
			}
			if test.wantStatus == http.StatusNotModified && response.Body.Len() != 0 {
				t.Fatalf("304 body = %q", response.Body.String())
			}
		})
	}
}

func TestAccessLogReportsWrittenBytesAndCacheFreshness(t *testing.T) {
	var output bytes.Buffer
	server := &Server{logger: slog.New(slog.NewJSONHandler(&output, nil))}
	checkedAt := time.Now().UTC().Add(-2 * time.Second)
	handler := server.accessLog(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("X-Radar-Cache", string(cache.Hit))
		w.Header().Set("X-Data-Checked-At", checkedAt.Format(time.RFC3339Nano))
		w.WriteHeader(http.StatusAccepted)
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = io.WriteString(w, "alert body")
	}))

	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/api/v1/alerts", nil))

	var entry map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(output.Bytes()), &entry); err != nil {
		t.Fatal(err)
	}
	if entry["status"] != float64(http.StatusAccepted) {
		t.Fatalf("logged status = %#v", entry["status"])
	}
	if response.Code != http.StatusAccepted {
		t.Fatalf("response status = %d", response.Code)
	}
	if entry["response_bytes"] != float64(len("alert body")) {
		t.Fatalf("logged response bytes = %#v", entry["response_bytes"])
	}
	if entry["cache_state"] != string(cache.Hit) {
		t.Fatalf("logged cache state = %#v", entry["cache_state"])
	}
	age, ok := entry["data_checked_age_seconds"].(float64)
	if !ok || age < 1 || age > 10 {
		t.Fatalf("logged checked age = %#v", entry["data_checked_age_seconds"])
	}
}

func TestStationTileRequiresGeneration(t *testing.T) {
	c := config.Config{
		UserAgent:        "radar-test",
		UpstreamTimeout:  time.Second,
		StaleTTL:         time.Minute,
		CacheMaxEntries:  8,
		CacheMaxBytes:    1 << 20,
		MaxUpstreamBytes: 1 << 20,
		TileMaxZoom:      16,
		Reflectivity:     map[string]string{"0.5": "sr_bref"},
		Velocity:         map[string]string{"0.5": "sr_bvel"},
	}
	server := New(c, slog.New(slog.NewTextHandler(io.Discard, nil)))
	request := httptest.NewRequest(http.MethodGet, "/api/v1/radar/tiles/velocity/KGRK/0.5/7/30/47.png", nil)
	response := httptest.NewRecorder()
	server.Handler().ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400: %s", response.Code, response.Body.String())
	}
	var body map[string]map[string]string
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body["error"]["code"] != "invalid_generation" {
		t.Fatalf("response = %#v", body)
	}
}

func TestAggregateTileRejectsInvalidSignedSnapshot(t *testing.T) {
	c := config.Config{
		UserAgent:         "radar-test",
		AggregateTokenKey: "0123456789abcdef0123456789abcdef",
		UpstreamTimeout:   time.Second,
		StaleTTL:          time.Minute,
		CacheMaxEntries:   8,
		CacheMaxBytes:     1 << 20,
		MaxUpstreamBytes:  1 << 20,
		TileMaxZoom:       16,
		Reflectivity:      map[string]string{"0.5": "sr_bref"},
		Velocity:          map[string]string{"0.5": "sr_bvel"},
	}
	server := New(c, slog.New(slog.NewTextHandler(io.Discard, nil)))
	request := httptest.NewRequest(
		http.MethodGet,
		"/api/v1/radar/tiles/aggregate/conus/0.5/8/58/105.png?timestamp=aaaaaaaaaaaaaaaaaaaaaaaa&snapshot=tampered",
		nil,
	)
	response := httptest.NewRecorder()
	server.Handler().ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400: %s", response.Code, response.Body.String())
	}
	var body map[string]map[string]string
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body["error"]["code"] != "invalid_generation" {
		t.Fatalf("response = %#v", body)
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
