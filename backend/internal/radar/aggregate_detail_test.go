package radar

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/KeganHollern/radar-app/backend/internal/cache"
	"github.com/KeganHollern/radar-app/backend/internal/config"
	"github.com/KeganHollern/radar-app/backend/internal/upstream"
)

func TestAggregateTileAddsExactLocalSuperResolutionDetailAtHighZoom(t *testing.T) {
	globalAnchor := time.Date(2026, 7, 14, 2, 20, 0, 0, time.UTC)
	localAnchor := globalAnchor.Add(10 * time.Minute)
	futureScan := localAnchor.Add(5 * time.Minute)
	baseColor := color.NRGBA{R: 0x20, G: 0x21, B: 0x20, A: 0xff}
	strongColor := color.NRGBA{R: 0x28, G: 0xd6, B: 0x4a, A: 0xff}
	basePNG := solidRadarPNG(t, baseColor)
	overlay := image.NewNRGBA(image.Rect(0, 0, 256, 256))
	// The 10 dBZ station sample is filtered, while 20 dBZ replaces the
	// lower-resolution aggregate pixel.
	overlay.SetNRGBA(0, 0, color.NRGBA{R: 0x54, G: 0x8f, B: 0xbd, A: 0xff})
	overlay.SetNRGBA(1, 0, strongColor)
	overlayPNG := encodePNG(t, overlay)

	type mapRequest struct {
		path   string
		layers string
		at     string
	}
	var mu sync.Mutex
	var requests []mapRequest
	var catalogCalls int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/stations" {
			mu.Lock()
			catalogCalls++
			mu.Unlock()
			w.Header().Set("Content-Type", "application/geo+json")
			_, _ = w.Write([]byte(aggregateDetailStationCatalog()))
			return
		}

		switch strings.ToLower(r.URL.Query().Get("request")) {
		case "getcapabilities":
			if r.URL.Path != "/kgrk/ows" {
				http.Error(w, "unexpected capabilities endpoint", http.StatusBadRequest)
				return
			}
			writeRadarCapability(w, "kgrk_sr_bref", futureScan, globalAnchor, localAnchor, futureScan)
		case "getmap":
			request := mapRequest{
				path:   r.URL.Path,
				layers: r.URL.Query().Get("layers"),
				at:     r.URL.Query().Get("time"),
			}
			mu.Lock()
			requests = append(requests, request)
			mu.Unlock()
			w.Header().Set("Content-Type", "image/png")
			if r.URL.Path == "/conus/conus_bref_qcd/ows" {
				_, _ = w.Write(basePNG)
				return
			}
			if r.URL.Path == "/kgrk/ows" {
				_, _ = w.Write(overlayPNG)
				return
			}
			http.Error(w, "unexpected map endpoint", http.StatusBadRequest)
		default:
			http.Error(w, "unexpected request", http.StatusBadRequest)
		}
	}))
	defer server.Close()

	service := newAggregateDetailTestService(server)
	result, err := service.aggregateTile(
		context.Background(),
		Selection{Product: "aggregate", Station: "conus", Elevation: "0.5"},
		Latest{
			ObservedAt: globalAnchor,
			Version:    "aggregate-generation",
			Components: map[string]LatestComponent{
				"alaska": {ObservedAt: globalAnchor},
				"conus":  {ObservedAt: localAnchor},
			},
		},
		9,
		116,
		210,
	)
	if err != nil {
		t.Fatal(err)
	}

	mu.Lock()
	gotRequests := append([]mapRequest(nil), requests...)
	gotCatalogCalls := catalogCalls
	mu.Unlock()
	if gotCatalogCalls != 1 {
		t.Fatalf("station catalog calls = %d, want 1", gotCatalogCalls)
	}
	if len(gotRequests) != 2 {
		t.Fatalf("GetMap requests = %#v, want one aggregate and one station request", gotRequests)
	}
	var baseRequest, stationRequest *mapRequest
	for index := range gotRequests {
		switch gotRequests[index].path {
		case "/conus/conus_bref_qcd/ows":
			baseRequest = &gotRequests[index]
		case "/kgrk/ows":
			stationRequest = &gotRequests[index]
		}
	}
	if baseRequest == nil || baseRequest.layers != aggregateLayer {
		t.Fatalf("aggregate request = %#v", baseRequest)
	}
	if baseRequest.at != localAnchor.Format(time.RFC3339) {
		t.Fatalf("aggregate time = %q, want local CONUS anchor %q", baseRequest.at, localAnchor.Format(time.RFC3339))
	}
	if stationRequest == nil {
		t.Fatal("missing KGRK station request")
	}
	if stationRequest.layers != "kgrk_sr_bref" {
		t.Fatalf("station layer = %q, want one KGRK layer", stationRequest.layers)
	}
	if stationRequest.at != localAnchor.Format(time.RFC3339) {
		t.Fatalf("station time = %q, want local CONUS anchor %q", stationRequest.at, localAnchor.Format(time.RFC3339))
	}

	composite, err := png.Decode(bytes.NewReader(result.Value.Body))
	if err != nil {
		t.Fatal(err)
	}
	if got := color.NRGBAModel.Convert(composite.At(0, 0)).(color.NRGBA); got != baseColor {
		t.Fatalf("weak detail pixel = %#v, want aggregate base %#v", got, baseColor)
	}
	if got := color.NRGBAModel.Convert(composite.At(1, 0)).(color.NRGBA); got != strongColor {
		t.Fatalf("strong detail pixel = %#v, want super-resolution %#v", got, strongColor)
	}
}

func TestAggregateTileKeepsRegionalMosaicBelowDetailZoom(t *testing.T) {
	anchor := time.Date(2026, 7, 14, 2, 30, 0, 0, time.UTC)
	basePNG := solidRadarPNG(t, color.NRGBA{A: 0xff})
	var stationCatalogCalls atomic.Int32
	var getMapCalls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/stations" {
			stationCatalogCalls.Add(1)
			http.Error(w, "low zoom must not fetch stations", http.StatusInternalServerError)
			return
		}
		if strings.EqualFold(r.URL.Query().Get("request"), "GetMap") {
			getMapCalls.Add(1)
			if r.URL.Path != "/conus/conus_bref_qcd/ows" {
				t.Errorf("path = %q, want exact CONUS endpoint", r.URL.Path)
			}
			if got := r.URL.Query().Get("layers"); got != aggregateLayer {
				t.Errorf("layers = %q, want CONUS aggregate", got)
			}
			if got := r.URL.Query().Get("time"); got != anchor.Format(time.RFC3339) {
				t.Errorf("time = %q, want pinned %q", got, anchor.Format(time.RFC3339))
			}
			w.Header().Set("Content-Type", "image/png")
			_, _ = w.Write(basePNG)
			return
		}
		http.Error(w, "unexpected request", http.StatusBadRequest)
	}))
	defer server.Close()

	service := newAggregateDetailTestService(server)
	result, err := service.aggregateTile(
		context.Background(),
		Selection{Product: "aggregate", Station: "conus", Elevation: "0.5"},
		Latest{
			Version: "generation",
			Components: map[string]LatestComponent{
				"conus": {ObservedAt: anchor},
			},
		},
		8,
		58,
		105,
	)
	if err != nil {
		t.Fatal(err)
	}
	if stationCatalogCalls.Load() != 0 {
		t.Fatalf("station catalog calls = %d, want 0", stationCatalogCalls.Load())
	}
	if getMapCalls.Load() != 1 {
		t.Fatalf("GetMap calls = %d, want 1", getMapCalls.Load())
	}
	if !bytes.Equal(result.Value.Body, basePNG) {
		t.Fatal("low-zoom aggregate tile was modified")
	}
}

func TestAggregateNationalOverviewCompositesExactRegionalGenerations(t *testing.T) {
	latest := Latest{
		Version:    "national-generation",
		Components: make(map[string]LatestComponent, len(aggregateRegions)),
	}
	regionPNGs := make(map[string][]byte, len(aggregateRegions))
	regionColors := make(map[string]color.NRGBA, len(aggregateRegions))
	for index, region := range aggregateRegions {
		observedAt := time.Date(2026, 7, 14, 2, index, 0, 0, time.UTC)
		latest.Components[region.name] = LatestComponent{ObservedAt: observedAt}
		value := color.NRGBA{R: uint8(30 + index*30), G: uint8(200 - index*20), B: uint8(50 + index*10), A: 0xff}
		regionColors[region.name] = value
		source := image.NewNRGBA(image.Rect(0, 0, 256, 256))
		source.SetNRGBA(index, 0, value)
		regionPNGs[region.layer] = encodePNG(t, source)
	}

	var mu sync.Mutex
	requestTimes := make(map[string]string, len(aggregateRegions))
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.EqualFold(r.URL.Query().Get("request"), "GetMap") {
			http.Error(w, "unexpected request", http.StatusBadRequest)
			return
		}
		layer := r.URL.Query().Get("layers")
		body, ok := regionPNGs[layer]
		if !ok {
			http.Error(w, "unexpected layer", http.StatusBadRequest)
			return
		}
		mu.Lock()
		requestTimes[layer] = r.URL.Query().Get("time")
		mu.Unlock()
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write(body)
	}))
	defer server.Close()

	result, err := newAggregateDetailTestService(server).aggregateTile(
		context.Background(),
		Selection{Product: "aggregate"},
		latest,
		0,
		0,
		0,
	)
	if err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	gotTimes := make(map[string]string, len(requestTimes))
	for layer, requestedAt := range requestTimes {
		gotTimes[layer] = requestedAt
	}
	mu.Unlock()
	if len(gotTimes) != len(aggregateRegions) {
		t.Fatalf("national regional requests = %#v, want %d", gotTimes, len(aggregateRegions))
	}
	rendered, err := png.Decode(bytes.NewReader(result.Value.Body))
	if err != nil {
		t.Fatal(err)
	}
	for index, region := range aggregateRegions {
		wantTime := latest.Components[region.name].ObservedAt.Format(time.RFC3339)
		if gotTimes[region.layer] != wantTime {
			t.Fatalf("%s time = %q, want %q", region.name, gotTimes[region.layer], wantTime)
		}
		if got := color.NRGBAModel.Convert(rendered.At(index, 0)).(color.NRGBA); got != regionColors[region.name] {
			t.Fatalf("%s pixel = %#v, want %#v", region.name, got, regionColors[region.name])
		}
	}
}

func TestAggregateBoundaryTilesKeepAlaskaAndHawaiiThroughZoomSix(t *testing.T) {
	anchor := time.Date(2026, 7, 14, 2, 30, 0, 0, time.UTC)
	latest := Latest{
		Version: "boundary-generation",
		Components: map[string]LatestComponent{
			"alaska": {ObservedAt: anchor},
			"hawaii": {ObservedAt: anchor},
		},
	}
	alaskaImage := image.NewNRGBA(image.Rect(0, 0, 256, 256))
	alaskaImage.SetNRGBA(0, 0, color.NRGBA{R: 0x30, G: 0x80, B: 0xff, A: 0xff})
	hawaiiImage := image.NewNRGBA(image.Rect(0, 0, 256, 256))
	hawaiiImage.SetNRGBA(1, 0, color.NRGBA{R: 0x20, G: 0xd0, B: 0x70, A: 0xff})
	regionalPNGs := map[string][]byte{
		"alaska_bref_qcd": encodePNG(t, alaskaImage),
		"hawaii_bref_qcd": encodePNG(t, hawaiiImage),
	}
	var mu sync.Mutex
	requestCounts := make(map[string]int)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		layer := r.URL.Query().Get("layers")
		body, ok := regionalPNGs[layer]
		if !ok {
			http.Error(w, "unexpected layer", http.StatusBadRequest)
			return
		}
		mu.Lock()
		requestCounts[layer]++
		mu.Unlock()
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write(body)
	}))
	defer server.Close()

	service := newAggregateDetailTestService(server)
	for _, location := range []struct {
		name      string
		latitude  float64
		longitude float64
	}{
		{name: "Aleutians", latitude: 52, longitude: -170},
		{name: "Hawaii", latitude: 22, longitude: -155},
	} {
		x, y := slippyTileForLocation(6, location.latitude, location.longitude)
		result, err := service.aggregateTile(
			context.Background(),
			Selection{Product: "aggregate"},
			latest,
			6,
			x,
			y,
		)
		if err != nil {
			t.Fatalf("%s tile: %v", location.name, err)
		}
		rendered, err := png.Decode(bytes.NewReader(result.Value.Body))
		if err != nil {
			t.Fatal(err)
		}
		if color.NRGBAModel.Convert(rendered.At(0, 0)).(color.NRGBA).A == 0 ||
			color.NRGBAModel.Convert(rendered.At(1, 0)).(color.NRGBA).A == 0 {
			t.Fatalf("%s boundary tile omitted Alaska or Hawaii layer", location.name)
		}
	}
	mu.Lock()
	gotCounts := make(map[string]int, len(requestCounts))
	for layer, count := range requestCounts {
		gotCounts[layer] = count
	}
	mu.Unlock()
	for layer := range regionalPNGs {
		if gotCounts[layer] != 2 {
			t.Fatalf("%s requests = %d, want both boundary tiles", layer, gotCounts[layer])
		}
	}

	for _, location := range []struct {
		latitude  float64
		longitude float64
		region    string
	}{
		{latitude: 52, longitude: -170, region: "alaska"},
		{latitude: 22, longitude: -155, region: "hawaii"},
	} {
		x, y := slippyTileForLocation(7, location.latitude, location.longitude)
		if got := aggregateRegionNameForTile(7, x, y); got != location.region {
			t.Fatalf("zoom-7 tile region at %g,%g = %q, want %q", location.latitude, location.longitude, got, location.region)
		}
	}
}

func TestAggregateDetailRefreshesBehindCapabilitiesAndPinsGeneration(t *testing.T) {
	oldScan := time.Date(2026, 7, 14, 2, 20, 0, 0, time.UTC)
	anchorScan := oldScan.Add(5 * time.Minute)
	futureScan := anchorScan.Add(5 * time.Minute)
	overlayPNG := solidRadarPNG(t, color.NRGBA{R: 0x28, G: 0xd6, B: 0x4a, A: 0xff})
	var published atomic.Int32
	var capabilityCalls atomic.Int32
	var mapCalls atomic.Int32
	var mu sync.Mutex
	var requestedTimes []string

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/stations" {
			w.Header().Set("Content-Type", "application/geo+json")
			_, _ = w.Write([]byte(aggregateDetailStationCatalog()))
			return
		}
		switch strings.ToLower(r.URL.Query().Get("request")) {
		case "getcapabilities":
			capabilityCalls.Add(1)
			switch published.Load() {
			case 0:
				writeRadarCapability(w, "kgrk_sr_bref", oldScan, oldScan)
			case 1:
				writeRadarCapability(w, "kgrk_sr_bref", anchorScan, oldScan, anchorScan)
			default:
				writeRadarCapability(w, "kgrk_sr_bref", futureScan, oldScan, anchorScan, futureScan)
			}
		case "getmap":
			mapCalls.Add(1)
			mu.Lock()
			requestedTimes = append(requestedTimes, r.URL.Query().Get("time"))
			mu.Unlock()
			w.Header().Set("Content-Type", "image/png")
			_, _ = w.Write(overlayPNG)
		default:
			http.Error(w, "unexpected request", http.StatusBadRequest)
		}
	}))
	defer server.Close()

	service := newAggregateDetailTestService(server)
	endpoint := server.URL + "/kgrk/ows"
	if _, _, err := service.fetchLatestLayer(context.Background(), endpoint, "kgrk_sr_bref"); err != nil {
		t.Fatal(err)
	}
	published.Store(1)
	latest := Latest{
		Version: "stable-aggregate-generation",
		Components: map[string]LatestComponent{
			"conus": {ObservedAt: anchorScan},
		},
	}
	first, err := service.fetchAggregateStationDetail(context.Background(), latest, 9, 116, 210)
	if err != nil {
		t.Fatal(err)
	}
	if !first.observedAt.Equal(anchorScan) {
		t.Fatalf("first detail generation = %s, want %s", first.observedAt, anchorScan)
	}
	if capabilityCalls.Load() != 2 {
		t.Fatalf("capabilities calls = %d, want initial load plus forced refresh", capabilityCalls.Load())
	}

	// A newer station scan appearing upstream must not change an existing
	// aggregate generation or produce a second station tile cache entry.
	published.Store(2)
	second, err := service.fetchAggregateStationDetail(context.Background(), latest, 9, 116, 210)
	if err != nil {
		t.Fatal(err)
	}
	if !second.observedAt.Equal(anchorScan) {
		t.Fatalf("second detail generation = %s, want pinned %s", second.observedAt, anchorScan)
	}
	if capabilityCalls.Load() != 2 {
		t.Fatalf("capabilities calls after rollover = %d, want 2", capabilityCalls.Load())
	}
	if mapCalls.Load() != 1 {
		t.Fatalf("station GetMap calls = %d, want exact-generation cache hit", mapCalls.Load())
	}
	mu.Lock()
	gotTimes := append([]string(nil), requestedTimes...)
	mu.Unlock()
	if len(gotTimes) != 1 || gotTimes[0] != anchorScan.Format(time.RFC3339) {
		t.Fatalf("station GetMap times = %#v, want only %q", gotTimes, anchorScan.Format(time.RFC3339))
	}
}

func TestAggregateDetailTimeoutReturnsReadyRegionalTile(t *testing.T) {
	anchor := time.Date(2026, 7, 14, 2, 30, 0, 0, time.UTC)
	basePNG := solidRadarPNG(t, color.NRGBA{R: 0x20, G: 0x21, B: 0x20, A: 0xff})
	stationStarted := make(chan struct{})
	var startOnce sync.Once
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/stations" {
			w.Header().Set("Content-Type", "application/geo+json")
			_, _ = w.Write([]byte(aggregateDetailStationCatalog()))
			return
		}
		switch strings.ToLower(r.URL.Query().Get("request")) {
		case "getcapabilities":
			writeRadarCapability(w, "kgrk_sr_bref", anchor, anchor)
		case "getmap":
			if r.URL.Path == "/conus/conus_bref_qcd/ows" {
				w.Header().Set("Content-Type", "image/png")
				_, _ = w.Write(basePNG)
				return
			}
			startOnce.Do(func() { close(stationStarted) })
			<-r.Context().Done()
		default:
			http.Error(w, "unexpected request", http.StatusBadRequest)
		}
	}))
	defer server.Close()

	service := newAggregateDetailTestService(server)
	service.aggregateDetailTimeout = 75 * time.Millisecond
	startedAt := time.Now()
	result, err := service.aggregateTile(
		context.Background(),
		Selection{Product: "aggregate", Station: "conus", Elevation: "0.5"},
		Latest{
			Version: "generation",
			Components: map[string]LatestComponent{
				"conus": {ObservedAt: anchor},
			},
		},
		9,
		116,
		210,
	)
	elapsed := time.Since(startedAt)
	if err != nil {
		t.Fatal(err)
	}
	if elapsed > 750*time.Millisecond {
		t.Fatalf("optional station detail held the base tile for %s", elapsed)
	}
	if !bytes.Equal(result.Value.Body, basePNG) {
		t.Fatal("timed-out station detail changed the regional tile")
	}
	select {
	case <-stationStarted:
	default:
		t.Fatal("test did not reach the delayed station tile")
	}
}

func TestAggregateDetailMalformedImageFallsBackToRegionalTile(t *testing.T) {
	anchor := time.Date(2026, 7, 14, 2, 30, 0, 0, time.UTC)
	basePNG := solidRadarPNG(t, color.NRGBA{R: 0x20, G: 0x21, B: 0x20, A: 0xff})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/stations" {
			w.Header().Set("Content-Type", "application/geo+json")
			_, _ = w.Write([]byte(aggregateDetailStationCatalog()))
			return
		}
		switch strings.ToLower(r.URL.Query().Get("request")) {
		case "getcapabilities":
			writeRadarCapability(w, "kgrk_sr_bref", anchor, anchor)
		case "getmap":
			w.Header().Set("Content-Type", "image/png")
			if r.URL.Path == "/conus/conus_bref_qcd/ows" {
				_, _ = w.Write(basePNG)
				return
			}
			_, _ = w.Write([]byte("not a PNG"))
		default:
			http.Error(w, "unexpected request", http.StatusBadRequest)
		}
	}))
	defer server.Close()

	service := newAggregateDetailTestService(server)
	result, err := service.aggregateTile(
		context.Background(),
		Selection{Product: "aggregate", Station: "conus", Elevation: "0.5"},
		Latest{
			Version: "generation",
			Components: map[string]LatestComponent{
				"conus": {ObservedAt: anchor},
			},
		},
		9,
		116,
		210,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(result.Value.Body, basePNG) {
		t.Fatal("malformed optional station image changed the regional tile")
	}
}

func TestAggregateDetailStaleStationFallsBackToRegionalTile(t *testing.T) {
	anchor := time.Date(2026, 7, 14, 2, 30, 0, 0, time.UTC)
	staleScan := anchor.Add(-30 * time.Minute)
	basePNG := solidRadarPNG(t, color.NRGBA{R: 0x20, G: 0x21, B: 0x20, A: 0xff})
	var capabilityCalls atomic.Int32
	var stationMapCalls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/stations" {
			w.Header().Set("Content-Type", "application/geo+json")
			_, _ = w.Write([]byte(aggregateDetailStationCatalog()))
			return
		}
		switch strings.ToLower(r.URL.Query().Get("request")) {
		case "getcapabilities":
			capabilityCalls.Add(1)
			writeRadarCapability(w, "kgrk_sr_bref", staleScan, staleScan)
		case "getmap":
			w.Header().Set("Content-Type", "image/png")
			if r.URL.Path == "/conus/conus_bref_qcd/ows" {
				_, _ = w.Write(basePNG)
				return
			}
			stationMapCalls.Add(1)
			_, _ = w.Write(basePNG)
		default:
			http.Error(w, "unexpected request", http.StatusBadRequest)
		}
	}))
	defer server.Close()

	service := newAggregateDetailTestService(server)
	result, err := service.aggregateTile(
		context.Background(),
		Selection{Product: "aggregate", Station: "conus", Elevation: "0.5"},
		Latest{
			Version: "generation",
			Components: map[string]LatestComponent{
				"conus": {ObservedAt: anchor},
			},
		},
		9,
		116,
		210,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(result.Value.Body, basePNG) {
		t.Fatal("stale station scan changed the current regional tile")
	}
	if capabilityCalls.Load() != 2 {
		t.Fatalf("station capabilities calls = %d, want cached check plus refresh", capabilityCalls.Load())
	}
	if stationMapCalls.Load() != 0 {
		t.Fatalf("stale station GetMap calls = %d, want 0", stationMapCalls.Load())
	}
}

func TestAggregateHighZoomGenerationIsStableAcrossStationRollover(t *testing.T) {
	anchor := time.Date(2026, 7, 14, 2, 30, 0, 0, time.UTC)
	future := anchor.Add(5 * time.Minute)
	basePNG := solidRadarPNG(t, color.NRGBA{R: 0x20, G: 0x21, B: 0x20, A: 0xff})
	futurePNG := solidRadarPNG(t, color.NRGBA{R: 0xff, A: 0xff})
	transparentPNG := encodePNG(t, image.NewNRGBA(image.Rect(0, 0, 256, 256)))
	var rolledOver atomic.Bool
	var mu sync.Mutex
	var baseTimes []string

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/stations" {
			w.Header().Set("Content-Type", "application/geo+json")
			_, _ = w.Write([]byte(aggregateDetailStationCatalog()))
			return
		}
		switch strings.ToLower(r.URL.Query().Get("request")) {
		case "getcapabilities":
			if rolledOver.Load() {
				writeRadarCapability(w, "kgrk_sr_bref", future, anchor, future)
				return
			}
			writeRadarCapability(w, "kgrk_sr_bref", anchor, anchor)
		case "getmap":
			w.Header().Set("Content-Type", "image/png")
			requestedAt := r.URL.Query().Get("time")
			if r.URL.Path == "/conus/conus_bref_qcd/ows" {
				mu.Lock()
				baseTimes = append(baseTimes, requestedAt)
				mu.Unlock()
				if requestedAt == anchor.Format(time.RFC3339) {
					_, _ = w.Write(basePNG)
				} else {
					_, _ = w.Write(futurePNG)
				}
				return
			}
			_, _ = w.Write(transparentPNG)
		default:
			http.Error(w, "unexpected request", http.StatusBadRequest)
		}
	}))
	defer server.Close()

	latest := Latest{
		Version: "stable-generation",
		Components: map[string]LatestComponent{
			"conus": {ObservedAt: anchor},
		},
	}
	selection := Selection{Product: "aggregate", Station: "conus", Elevation: "0.5"}
	first, err := newAggregateDetailTestService(server).aggregateTile(
		context.Background(),
		selection,
		latest,
		9,
		116,
		210,
	)
	if err != nil {
		t.Fatal(err)
	}
	rolledOver.Store(true)
	second, err := newAggregateDetailTestService(server).aggregateTile(
		context.Background(),
		selection,
		latest,
		9,
		116,
		210,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first.Value.Body, second.Value.Body) {
		t.Fatal("identical aggregate generation changed after station rollover")
	}
	mu.Lock()
	gotBaseTimes := append([]string(nil), baseTimes...)
	mu.Unlock()
	wantTime := anchor.Format(time.RFC3339)
	if len(gotBaseTimes) != 2 || gotBaseTimes[0] != wantTime || gotBaseTimes[1] != wantTime {
		t.Fatalf("base times across rollover = %#v, want two %q requests", gotBaseTimes, wantTime)
	}
}

func TestAggregateTileURLRejectsDifferentGenerationAcrossReplicas(t *testing.T) {
	firstObservation := time.Date(2026, 7, 14, 2, 30, 0, 0, time.UTC)
	secondObservation := firstObservation.Add(5 * time.Minute)
	firstPNG := solidRadarPNG(t, color.NRGBA{R: 0x20, G: 0x21, B: 0x20, A: 0xff})
	secondPNG := solidRadarPNG(t, color.NRGBA{R: 0xff, A: 0xff})
	var rolledOver atomic.Bool
	var mapCalls atomic.Int32

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch strings.ToLower(r.URL.Query().Get("request")) {
		case "getcapabilities":
			parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
			if len(parts) != 3 {
				http.Error(w, "unexpected capabilities endpoint", http.StatusBadRequest)
				return
			}
			observedAt := firstObservation
			if rolledOver.Load() {
				observedAt = secondObservation
			}
			writeRadarCapability(w, parts[1], observedAt, observedAt)
		case "getmap":
			mapCalls.Add(1)
			w.Header().Set("Content-Type", "image/png")
			if rolledOver.Load() {
				_, _ = w.Write(secondPNG)
			} else {
				_, _ = w.Write(firstPNG)
			}
		default:
			http.Error(w, "unexpected request", http.StatusBadRequest)
		}
	}))
	defer server.Close()

	observations := make(map[string]time.Time, len(aggregateRegions))
	for _, region := range aggregateRegions {
		observations[region.name] = firstObservation
	}
	firstGeneration := aggregateVersion(observations, nil)
	selection := Selection{Product: "aggregate"}
	first, err := newAggregateDetailTestService(server).Tile(
		context.Background(),
		selection,
		firstGeneration,
		8,
		58,
		105,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first.Value.Body, firstPNG) {
		t.Fatal("first replica returned unexpected aggregate bytes")
	}

	rolledOver.Store(true)
	_, err = newAggregateDetailTestService(server).Tile(
		context.Background(),
		selection,
		firstGeneration,
		8,
		58,
		105,
	)
	if !errors.Is(err, ErrInvalidGeneration) {
		t.Fatalf("old aggregate URL after rollover error = %v, want invalid generation", err)
	}
	if mapCalls.Load() != 1 {
		t.Fatalf("aggregate GetMap calls = %d, want no current bytes under old URL", mapCalls.Load())
	}
}

func TestAggregateTileRetainsKnownGenerationAcrossWarmReplicaRollover(t *testing.T) {
	firstObservation := time.Date(2026, 7, 14, 2, 30, 0, 0, time.UTC)
	secondObservation := firstObservation.Add(5 * time.Minute)
	firstPNG := solidRadarPNG(t, color.NRGBA{R: 0x20, G: 0x21, B: 0x20, A: 0xff})
	secondPNG := solidRadarPNG(t, color.NRGBA{R: 0xff, A: 0xff})
	transparentPNG := encodePNG(t, image.NewNRGBA(image.Rect(0, 0, 256, 256)))
	var rolledOver atomic.Bool
	var mu sync.Mutex
	var mapTimes []string

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/stations" {
			w.Header().Set("Content-Type", "application/geo+json")
			_, _ = w.Write([]byte(aggregateDetailStationCatalog()))
			return
		}
		switch strings.ToLower(r.URL.Query().Get("request")) {
		case "getcapabilities":
			if r.URL.Path == "/kgrk/ows" {
				if rolledOver.Load() {
					writeRadarCapability(w, "kgrk_sr_bref", secondObservation, firstObservation, secondObservation)
				} else {
					writeRadarCapability(w, "kgrk_sr_bref", firstObservation, firstObservation)
				}
				return
			}
			parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
			if len(parts) != 3 {
				http.Error(w, "unexpected capabilities endpoint", http.StatusBadRequest)
				return
			}
			observedAt := firstObservation
			if rolledOver.Load() {
				observedAt = secondObservation
			}
			writeRadarCapability(w, parts[1], observedAt, observedAt)
		case "getmap":
			requestedAt := r.URL.Query().Get("time")
			mu.Lock()
			mapTimes = append(mapTimes, r.URL.Path+"="+requestedAt)
			mu.Unlock()
			w.Header().Set("Content-Type", "image/png")
			if r.URL.Path == "/conus/conus_bref_qcd/ows" {
				if requestedAt == firstObservation.Format(time.RFC3339) {
					_, _ = w.Write(firstPNG)
				} else {
					_, _ = w.Write(secondPNG)
				}
				return
			}
			_, _ = w.Write(transparentPNG)
		default:
			http.Error(w, "unexpected request", http.StatusBadRequest)
		}
	}))
	defer server.Close()

	service := newAggregateDetailTestService(server)
	service.config.MetadataTTL = time.Nanosecond
	firstLatest, err := service.Latest(context.Background(), Selection{Product: "aggregate"})
	if err != nil {
		t.Fatal(err)
	}
	rolledOver.Store(true)
	result, err := service.Tile(
		context.Background(),
		Selection{Product: "aggregate"},
		firstLatest.Version,
		9,
		116,
		210,
	)
	if err != nil {
		t.Fatal(err)
	}
	rendered, err := png.Decode(bytes.NewReader(result.Value.Body))
	if err != nil {
		t.Fatal(err)
	}
	if got := color.NRGBAModel.Convert(rendered.At(0, 0)).(color.NRGBA); got != (color.NRGBA{R: 0x20, G: 0x21, B: 0x20, A: 0xff}) {
		t.Fatalf("remembered generation pixel = %#v, want first-generation base", got)
	}
	mu.Lock()
	gotMapTimes := append([]string(nil), mapTimes...)
	mu.Unlock()
	wantTime := firstObservation.Format(time.RFC3339)
	if len(gotMapTimes) != 2 {
		t.Fatalf("remembered generation maps = %#v, want base and station", gotMapTimes)
	}
	for _, got := range gotMapTimes {
		if !strings.HasSuffix(got, "="+wantTime) {
			t.Fatalf("remembered generation map = %q, want exact %q time", got, wantTime)
		}
	}
	regional, err := service.Tile(
		context.Background(),
		Selection{Product: "aggregate"},
		firstLatest.Version,
		8,
		58,
		105,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(regional.Value.Body, firstPNG) {
		t.Fatal("remembered zoom-8 generation did not retain exact regional bytes")
	}
	mu.Lock()
	regionalMap := mapTimes[len(mapTimes)-1]
	mu.Unlock()
	if regionalMap != "/conus/conus_bref_qcd/ows="+wantTime {
		t.Fatalf("remembered zoom-8 map = %q, want pinned CONUS generation", regionalMap)
	}

	_, err = service.Tile(
		context.Background(),
		Selection{Product: "aggregate"},
		strings.Repeat("f", 24),
		9,
		116,
		210,
	)
	if !errors.Is(err, ErrInvalidGeneration) {
		t.Fatalf("unknown aggregate generation error = %v, want invalid generation", err)
	}
	mu.Lock()
	mapCount := len(mapTimes)
	mu.Unlock()
	if mapCount != 3 {
		t.Fatalf("unknown generation triggered GetMap; map calls = %d", mapCount)
	}
}

func TestAggregateDetailStationSelectionIsStableAcrossAdjacentTiles(t *testing.T) {
	body := []byte(aggregateDetailStationCatalog())
	first, err := nearestAggregateDetailStation(body, 9, 116, 210)
	if err != nil {
		t.Fatal(err)
	}
	second, err := nearestAggregateDetailStation(body, 9, 117, 210)
	if err != nil {
		t.Fatal(err)
	}
	if first.id != "KGRK" || second.id != first.id {
		t.Fatalf("adjacent tile stations = %q and %q, want stable KGRK source", first.id, second.id)
	}
	firstZ, firstX, firstY := aggregateDetailSelectionTile(9, 116, 210)
	secondZ, secondX, secondY := aggregateDetailSelectionTile(9, 117, 210)
	if firstZ != secondZ || firstX != secondX || firstY != secondY {
		t.Fatalf(
			"adjacent tiles selected different parents: %d/%d/%d and %d/%d/%d",
			firstZ,
			firstX,
			firstY,
			secondZ,
			secondX,
			secondY,
		)
	}
}

func TestAggregateRegionForLocationHandlesAlaskaAcrossDateline(t *testing.T) {
	for _, longitude := range []float64{-170, 170} {
		if got := aggregateRegionForLocation(52, longitude); got != "alaska" {
			t.Fatalf("region at 52,%g = %q, want alaska", longitude, got)
		}
	}
	if got := aggregateRegionForLocation(13.45, 144.75); got != "guam" {
		t.Fatalf("Guam region = %q, want guam", got)
	}
}

func aggregateDetailStationCatalog() string {
	return "{\"type\":\"FeatureCollection\",\"features\":[" +
		"{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[-97.3828,30.7218]},\"properties\":{\"rda_id\":\"KGRK\"}}," +
		"{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[-97.3031,32.5731]},\"properties\":{\"rda_id\":\"KFWS\"}}," +
		"{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[-98.4131,45.4558]},\"properties\":{\"rda_id\":\"KABR\"}}," +
		"{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[-97.3000,32.8000]},\"properties\":{\"rda_id\":\"TDFW\"}}" +
		"]}"
}

func writeRadarCapability(w http.ResponseWriter, layer string, defaultTime time.Time, observations ...time.Time) {
	values := make([]string, len(observations))
	for index, observedAt := range observations {
		values[index] = observedAt.UTC().Format(time.RFC3339Nano)
	}
	w.Header().Set("Content-Type", "application/xml")
	_, _ = fmt.Fprintf(
		w,
		"<WMS_Capabilities><Capability><Layer><Layer><Name>%s</Name><Dimension name=\"time\" default=\"%s\">%s</Dimension></Layer></Layer></Capability></WMS_Capabilities>",
		layer,
		defaultTime.UTC().Format(time.RFC3339Nano),
		strings.Join(values, ","),
	)
}

func solidRadarPNG(t *testing.T, value color.NRGBA) []byte {
	t.Helper()
	source := image.NewNRGBA(image.Rect(0, 0, 256, 256))
	for offset := 0; offset < len(source.Pix); offset += 4 {
		source.Pix[offset] = value.R
		source.Pix[offset+1] = value.G
		source.Pix[offset+2] = value.B
		source.Pix[offset+3] = value.A
	}
	return encodePNG(t, source)
}

func slippyTileForLocation(z int, latitude, longitude float64) (int, int) {
	scale := math.Exp2(float64(z))
	x := int((longitude + 180) / 360 * scale)
	latitudeRadians := latitude * math.Pi / 180
	y := int((1 - math.Asinh(math.Tan(latitudeRadians))/math.Pi) / 2 * scale)
	return x, y
}

func newAggregateDetailTestService(server *httptest.Server) *Service {
	c := config.Config{
		RadarBaseURL:    server.URL,
		StationsURL:     server.URL + "/stations",
		StationTTL:      time.Hour,
		MetadataTTL:     time.Minute,
		TileTTL:         time.Minute,
		RadarStaleAfter: time.Hour,
		TileMaxZoom:     16,
		Reflectivity:    map[string]string{"0.5": "sr_bref"},
		Velocity:        map[string]string{"0.5": "sr_bvel"},
	}
	fetcher := upstream.NewFetcher(server.Client(), cache.New(128, 32<<20), "radar-test", 16<<20, time.Minute)
	return NewService(c, fetcher)
}
