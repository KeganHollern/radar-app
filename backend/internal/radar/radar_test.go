package radar

import (
	"context"
	"errors"
	"image"
	"math"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/KeganHollern/radar-app/backend/internal/cache"
	"github.com/KeganHollern/radar-app/backend/internal/config"
	"github.com/KeganHollern/radar-app/backend/internal/upstream"
)

func TestTileBounds(t *testing.T) {
	b := tileBounds(0, 0, 0)
	want := math.Pi * 6378137
	if math.Abs(b.minX+want) > 0.001 || math.Abs(b.maxY-want) > 0.001 || math.Abs(b.maxX-want) > 0.001 || math.Abs(b.minY+want) > 0.001 {
		t.Fatalf("unexpected world bounds: %#v", b)
	}
}

func TestWMSQueryRequestsTransparentPNG(t *testing.T) {
	observedAt := time.Date(2026, 7, 12, 20, 10, 0, 0, time.UTC)
	query := pinnedWMSQuery("kdmx_sr_bref", tileBounds(7, 30, 47), observedAt)
	if got := query.Get("format"); got != "image/png" {
		t.Fatalf("format = %q, want image/png", got)
	}
	if got := query.Get("transparent"); got != "true" {
		t.Fatalf("transparent = %q, want true", got)
	}
	if got := query.Get("time"); got != "2026-07-12T20:10:00Z" {
		t.Fatalf("time = %q, want pinned observation", got)
	}
}

func TestAggregateUsesAllUSCoverageLayers(t *testing.T) {
	service := &Service{config: config.Config{RadarBaseURL: "https://example.test/geoserver"}}
	endpoint, layer := service.tileEndpointLayer(Selection{Product: "aggregate"})
	if endpoint != "https://example.test/geoserver/ows" {
		t.Fatalf("endpoint = %q", endpoint)
	}
	for _, want := range []string{"conus:", "alaska:", "hawaii:", "carib:", "guam:"} {
		if !strings.Contains(layer, want) {
			t.Fatalf("aggregate layers %q missing %q", layer, want)
		}
	}
}

func TestAggregateVersionIncludesEveryRegion(t *testing.T) {
	base := map[string]time.Time{
		"conus":     time.Unix(100, 0),
		"alaska":    time.Unix(200, 0),
		"hawaii":    time.Unix(190, 0),
		"caribbean": time.Unix(180, 0),
		"guam":      time.Unix(170, 0),
	}
	first := aggregateVersion(base, nil)
	base["alaska"] = time.Unix(201, 0)
	second := aggregateVersion(base, nil)
	if first == second {
		t.Fatal("regional timestamp change did not change aggregate generation")
	}
	if second == aggregateVersion(base, []string{"guam"}) {
		t.Fatal("missing region did not change aggregate generation")
	}
	if len(second) != 24 {
		t.Fatalf("aggregate generation length = %d, want existing 24-character format", len(second))
	}
	if got := wmsQuery(aggregateTileLayers, tileBounds(0, 0, 0)).Get("time"); got != "" {
		t.Fatalf("aggregate WMS time = %q; regional layers do not share one exact generation", got)
	}
}

func TestLatestLayerTime(t *testing.T) {
	body := []byte(`<WMS_Capabilities><Capability><Layer><Layer><Name>kfws_sr_bref</Name><Dimension name="time" default="2026-07-12T20:10:00Z">2026-07-12T20:05:00Z,2026-07-12T20:10:00Z</Dimension></Layer></Layer></Capability></WMS_Capabilities>`)
	got, err := latestLayerTime(body, "kfws_sr_bref")
	if err != nil {
		t.Fatal(err)
	}
	want := time.Date(2026, 7, 12, 20, 10, 0, 0, time.UTC)
	if !got.Equal(want) {
		t.Fatalf("got %s want %s", got, want)
	}
}

func TestLatestLayerTimeIncludesDefaultOmittedFromValues(t *testing.T) {
	body := []byte(`<WMS_Capabilities><Capability><Layer><Layer><Name>kfws_sr_bref</Name><Dimension name="time" default="2026-07-12T20:10:00Z">2026-07-12T20:00:00Z,2026-07-12T20:05:00Z</Dimension></Layer></Layer></Capability></WMS_Capabilities>`)
	observations, err := layerObservationTimes(body, "kfws_sr_bref")
	if err != nil {
		t.Fatal(err)
	}
	want := time.Date(2026, 7, 12, 20, 10, 0, 0, time.UTC)
	if !containsObservation(observations, want) {
		t.Fatalf("default observation %s missing from %#v", want, observations)
	}
	if got, err := latestLayerTime(body, "kfws_sr_bref"); err != nil || !got.Equal(want) {
		t.Fatalf("latest = %s, %v; want %s", got, err, want)
	}
}

func TestGenerationValidationIsRecentAndAvailable(t *testing.T) {
	latest := time.Date(2026, 7, 12, 20, 20, 0, 0, time.UTC)
	if err := validateGenerationTime(latest.Add(-tileGenerationGrace), latest); err != nil {
		t.Fatal(err)
	}
	if err := validateGenerationTime(latest.Add(-tileGenerationGrace-time.Millisecond), latest); !errors.Is(err, ErrInvalidGeneration) {
		t.Fatalf("expired generation error = %v", err)
	}
	if err := validateGenerationTime(latest.Add(time.Millisecond), latest); !errors.Is(err, ErrInvalidGeneration) {
		t.Fatalf("future generation error = %v", err)
	}
	for _, generation := range []string{"", "not-a-time", "123-bad", " 123", "+123", "00123"} {
		if _, err := parseGenerationTime("velocity", generation); !errors.Is(err, ErrInvalidGeneration) {
			t.Fatalf("parse %q error = %v", generation, err)
		}
	}
}

func TestStationTilePinsRequestedGeneration(t *testing.T) {
	older := time.Date(2026, 7, 12, 20, 5, 0, 0, time.UTC)
	middle := older.Add(5 * time.Minute)
	advanced := older.Add(10 * time.Minute)
	var latestMilliseconds atomic.Int64
	latestMilliseconds.Store(middle.UnixMilli())
	var capabilityCalls atomic.Int32
	times := make(chan string, 2)
	tilePNG := encodePNG(t, image.NewNRGBA(image.Rect(0, 0, 256, 256)))
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch strings.ToLower(r.URL.Query().Get("request")) {
		case "getcapabilities":
			capabilityCalls.Add(1)
			latest := time.UnixMilli(latestMilliseconds.Load()).UTC()
			values := older.Format(time.RFC3339) + `,` + middle.Format(time.RFC3339)
			if latest.After(middle) {
				values += `,` + latest.Format(time.RFC3339)
			}
			w.Header().Set("Content-Type", "application/xml")
			_, _ = w.Write([]byte(`<WMS_Capabilities><Capability><Layer>` +
				`<Layer><Name>kgrk_sr_bvel</Name><Dimension name="time" default="` + latest.Format(time.RFC3339) + `">` + values + `</Dimension></Layer>` +
				`<Layer><Name>kgrk_sr_bref</Name><Dimension name="time" default="` + latest.Format(time.RFC3339) + `">` + values + `</Dimension></Layer>` +
				`</Layer></Capability></WMS_Capabilities>`))
		case "getmap":
			times <- r.URL.Query().Get("layers") + "=" + r.URL.Query().Get("time")
			w.Header().Set("Content-Type", "image/png")
			_, _ = w.Write(tilePNG)
		default:
			http.Error(w, "unexpected request", http.StatusBadRequest)
		}
	}))
	defer server.Close()

	c := config.Config{
		RadarBaseURL:    server.URL,
		MetadataTTL:     time.Minute,
		TileTTL:         time.Minute,
		RadarStaleAfter: time.Hour,
		TileMaxZoom:     16,
		Reflectivity:    map[string]string{"0.5": "sr_bref"},
		Velocity:        map[string]string{"0.5": "sr_bvel"},
	}
	newService := func() *Service {
		fetcher := upstream.NewFetcher(server.Client(), cache.New(32, 4<<20), "radar-test", 1<<20, time.Minute)
		return NewService(c, fetcher)
	}
	service := newService()
	selection := Selection{Product: "velocity", Station: "KGRK", Elevation: "0.5"}
	generation := strconv.FormatInt(older.UnixMilli(), 10)

	if _, err := service.Tile(context.Background(), selection, generation, "", 0, 0, 0); err != nil {
		t.Fatal(err)
	}
	if got := <-times; got != "kgrk_sr_bvel="+older.Format(time.RFC3339) {
		t.Fatalf("first WMS generation = %q", got)
	}

	// A second zoom can reach another API replica after NOAA advances. The
	// manifest generation must still select exactly the same scan.
	latestMilliseconds.Store(advanced.UnixMilli())
	service = newService()
	if _, err := service.Tile(context.Background(), selection, generation, "", 1, 1, 1); err != nil {
		t.Fatal(err)
	}
	if got := <-times; got != "kgrk_sr_bvel="+older.Format(time.RFC3339) {
		t.Fatalf("second WMS generation = %q", got)
	}

	// Reflectivity shares the same station-generation resolver.
	reflectivity := Selection{Product: "reflectivity", Station: "KGRK", Elevation: "0.5"}
	if resolved, err := service.resolveTileGeneration(context.Background(), reflectivity, generation); err != nil || !resolved.observedAt.Equal(older) {
		t.Fatalf("reflectivity generation = %#v, %v", resolved, err)
	}

	unavailable := older.Add(time.Minute)
	callsBeforeUnavailable := capabilityCalls.Load()
	if _, err := service.Tile(context.Background(), selection, strconv.FormatInt(unavailable.UnixMilli(), 10), "", 0, 0, 0); !errors.Is(err, ErrInvalidGeneration) {
		t.Fatalf("unavailable generation error = %v", err)
	}
	if got := capabilityCalls.Load(); got != callsBeforeUnavailable {
		t.Fatalf("older unlisted generation caused capabilities refresh: calls %d -> %d", callsBeforeUnavailable, got)
	}
	if _, err := service.Tile(context.Background(), selection, "", "", 0, 0, 0); !errors.Is(err, ErrInvalidGeneration) {
		t.Fatalf("missing generation error = %v", err)
	}

	latestMilliseconds.Store(older.Add(20 * time.Minute).UnixMilli())
	service = newService()
	if _, err := service.Tile(context.Background(), selection, generation, "", 0, 0, 0); !errors.Is(err, ErrInvalidGeneration) {
		t.Fatalf("expired generation error = %v", err)
	}
}

func TestStationTileRefreshesCapabilitiesWhenReplicaCacheIsBehind(t *testing.T) {
	first := time.Date(2026, 7, 12, 20, 5, 0, 0, time.UTC)
	second := first.Add(5 * time.Minute)
	var upstreamLatest atomic.Int64
	upstreamLatest.Store(first.UnixMilli())
	var capabilityCalls atomic.Int32
	requestedTime := make(chan string, 1)
	tilePNG := encodePNG(t, image.NewNRGBA(image.Rect(0, 0, 256, 256)))
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch strings.ToLower(r.URL.Query().Get("request")) {
		case "getcapabilities":
			capabilityCalls.Add(1)
			latest := time.UnixMilli(upstreamLatest.Load()).UTC()
			values := first.Format(time.RFC3339)
			if latest.After(first) {
				values += "," + latest.Format(time.RFC3339)
			}
			w.Header().Set("Content-Type", "application/xml")
			_, _ = w.Write([]byte(`<WMS_Capabilities><Capability><Layer><Layer><Name>kgrk_sr_bvel</Name><Dimension name="time" default="` + latest.Format(time.RFC3339) + `">` + values + `</Dimension></Layer></Layer></Capability></WMS_Capabilities>`))
		case "getmap":
			requestedTime <- r.URL.Query().Get("time")
			w.Header().Set("Content-Type", "image/png")
			_, _ = w.Write(tilePNG)
		default:
			http.Error(w, "unexpected request", http.StatusBadRequest)
		}
	}))
	defer server.Close()

	c := config.Config{
		RadarBaseURL:    server.URL,
		MetadataTTL:     time.Minute,
		TileTTL:         time.Minute,
		RadarStaleAfter: time.Hour,
		TileMaxZoom:     16,
		Reflectivity:    map[string]string{"0.5": "sr_bref"},
		Velocity:        map[string]string{"0.5": "sr_bvel"},
	}
	fetcher := upstream.NewFetcher(server.Client(), cache.New(32, 4<<20), "radar-test", 1<<20, time.Minute)
	service := NewService(c, fetcher)
	selection := Selection{Product: "velocity", Station: "KGRK", Elevation: "0.5"}
	if _, err := service.Latest(context.Background(), selection); err != nil {
		t.Fatal(err)
	}

	// Simulate a manifest from replica A advertising T1 while this replica still
	// has T0 in its fresh 15-second capabilities cache.
	upstreamLatest.Store(second.UnixMilli())
	generation := strconv.FormatInt(second.UnixMilli(), 10)
	if _, err := service.Tile(context.Background(), selection, generation, "", 1, 1, 1); err != nil {
		t.Fatal(err)
	}
	if got := <-requestedTime; got != second.Format(time.RFC3339) {
		t.Fatalf("WMS time = %q, want %q", got, second.Format(time.RFC3339))
	}
	if got := capabilityCalls.Load(); got != 2 {
		t.Fatalf("capabilities calls = %d, want cached read plus one forced refresh", got)
	}
}

func TestValidateTile(t *testing.T) {
	if err := validateTile(2, 3, 3, 16); err != nil {
		t.Fatal(err)
	}
	if err := validateTile(2, 4, 0, 16); err == nil {
		t.Fatal("expected invalid x")
	}
}
