package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/KeganHollern/radar-app/backend/internal/config"
	"github.com/KeganHollern/radar-app/backend/internal/lightning"
)

func TestLightningLatestEnvelopeBoundsAndConditionalGet(t *testing.T) {
	server := newLightningTestServer(true)
	now := time.Now().UTC().Truncate(time.Second)
	server.lightning.Ingest(lightning.Batch{
		Source:    lightning.EastSourceID,
		ObjectKey: "current-scan",
		ObjectEnd: now.Add(-time.Second),
		Flashes: []lightning.Flash{
			{ID: "inside", Latitude: 30, Longitude: -95, ObservedAt: now.Add(-2 * time.Second), ReceivedAt: now, Satellite: "GOES-19"},
			{ID: "outside", Latitude: 45, Longitude: -80, ObservedAt: now.Add(-2 * time.Second), ReceivedAt: now, Satellite: "GOES-19"},
		},
	}, now)
	server.lightning.MarkChecked("G19", now)

	request := httptest.NewRequest(http.MethodGet, "/api/v1/lightning/latest?bbox=-104,20,-90,40", nil)
	response := httptest.NewRecorder()
	server.Handler().ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", response.Code, response.Body.String())
	}
	if response.Header().Get("Cache-Control") != "no-cache, no-store, must-revalidate" || response.Header().Get("ETag") == "" || response.Header().Get("X-Data-Checked-At") == "" {
		t.Fatalf("missing live response headers: %#v", response.Header())
	}
	var envelope lightning.Envelope
	if err := json.Unmarshal(response.Body.Bytes(), &envelope); err != nil {
		t.Fatal(err)
	}
	if envelope.SchemaVersion != "1" || envelope.Mode != "event" || !envelope.Available || envelope.Stale || envelope.Source != lightning.SourceName || envelope.Attribution != lightning.AttributionText {
		t.Fatalf("unexpected envelope: %#v", envelope)
	}
	if len(envelope.Data.Features) != 1 || envelope.Data.Features[0].ID != "inside" || envelope.Data.Features[0].Properties.Kind != lightning.FlashKind {
		t.Fatalf("unexpected features: %#v", envelope.Data.Features)
	}

	conditionalRequest := httptest.NewRequest(http.MethodGet, "/api/v1/lightning/latest?bbox=-104,20,-90,40", nil)
	conditionalRequest.Header.Set("If-None-Match", response.Header().Get("ETag"))
	conditional := httptest.NewRecorder()
	server.Handler().ServeHTTP(conditional, conditionalRequest)
	if conditional.Code != http.StatusNotModified || conditional.Body.Len() != 0 {
		t.Fatalf("conditional response = %d, %q", conditional.Code, conditional.Body.String())
	}
}

func TestLightningLatestStrictQueryAndDisabledState(t *testing.T) {
	server := newLightningTestServer(false)
	for _, target := range []string{
		"/api/v1/lightning/latest?bbox=-180,-90,180,90",
		"/api/v1/lightning/latest?bbox=-100,20,-90,40&bbox=-99,21,-91,39",
		"/api/v1/lightning/latest?bbox=",
		"/api/v1/lightning/latest?point=30,-90",
		"/api/v1/lightning/latest?bbox=-100,20,-90,40;point=30,-90",
	} {
		response := httptest.NewRecorder()
		server.Handler().ServeHTTP(response, httptest.NewRequest(http.MethodGet, target, nil))
		if response.Code != http.StatusBadRequest {
			t.Errorf("%s status = %d, want 400: %s", target, response.Code, response.Body.String())
		}
	}
	response := httptest.NewRecorder()
	server.Handler().ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/api/v1/lightning/latest", nil))
	var envelope lightning.Envelope
	if err := json.Unmarshal(response.Body.Bytes(), &envelope); err != nil {
		t.Fatal(err)
	}
	if response.Code != http.StatusOK || envelope.Available || envelope.CheckedAt != nil || len(envelope.Data.Features) != 0 {
		t.Fatalf("disabled envelope = %d %#v", response.Code, envelope)
	}
}

func TestLightningUpdatesStartsWithSnapshot(t *testing.T) {
	server := newLightningTestServer(true)
	ctx, cancel := context.WithCancel(context.Background())
	request := httptest.NewRequest(http.MethodGet, "/api/v1/lightning/updates?bbox=-170,5,-45,65", nil).WithContext(ctx)
	response := newStreamResponse()
	done := make(chan struct{})
	go func() {
		server.Handler().ServeHTTP(response, request)
		close(done)
	}()
	for index := 0; index < 2; index++ {
		select {
		case <-response.flushed:
		case <-time.After(time.Second):
			cancel()
			t.Fatal("timed out waiting for initial SSE snapshot")
		}
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("SSE handler did not stop after cancellation")
	}
	body := response.String()
	if !strings.Contains(body, "retry: 5000") || !strings.Contains(body, "event: snapshot") || !strings.Contains(body, `"schemaVersion":"1"`) || !strings.Contains(body, `"available":false`) {
		t.Fatalf("initial SSE body = %q", body)
	}
}

func newLightningTestServer(enabled bool) *Server {
	c := config.Config{
		PublicBaseURL:           "https://radar.example",
		AllowedOrigins:          []string{"*"},
		UserAgent:               "radar-test",
		UpstreamTimeout:         time.Second,
		StaleTTL:                time.Minute,
		CacheMaxEntries:         8,
		CacheMaxBytes:           1 << 20,
		MaxUpstreamBytes:        1 << 20,
		TileMaxZoom:             16,
		Reflectivity:            map[string]string{"0.5": "sr_bref"},
		Velocity:                map[string]string{"0.5": "sr_bvel"},
		LightningEnabled:        enabled,
		LightningPoll:           5 * time.Second,
		LightningRetention:      90 * time.Second,
		LightningStaleAfter:     90 * time.Second,
		LightningMaxFlashes:     100,
		LightningMaxObjectBytes: 1 << 20,
		LightningSeamLongitude:  -105,
	}
	return New(c, slog.New(slog.NewTextHandler(io.Discard, nil)))
}

type streamResponse struct {
	mu      sync.Mutex
	header  http.Header
	status  int
	body    bytes.Buffer
	flushed chan struct{}
}

func newStreamResponse() *streamResponse {
	return &streamResponse{header: make(http.Header), flushed: make(chan struct{}, 4)}
}

func (w *streamResponse) Header() http.Header { return w.header }

func (w *streamResponse) WriteHeader(status int) {
	w.mu.Lock()
	if w.status == 0 {
		w.status = status
	}
	w.mu.Unlock()
}

func (w *streamResponse) Write(body []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.status == 0 {
		w.status = http.StatusOK
	}
	return w.body.Write(body)
}

func (w *streamResponse) Flush() {
	select {
	case w.flushed <- struct{}{}:
	default:
	}
}

func (w *streamResponse) String() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.body.String()
}
