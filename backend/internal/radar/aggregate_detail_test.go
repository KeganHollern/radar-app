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
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/KeganHollern/radar-app/backend/internal/cache"
	"github.com/KeganHollern/radar-app/backend/internal/config"
	"github.com/KeganHollern/radar-app/backend/internal/upstream"
)

func TestAggregateNormalizePreservesExplicitDetailStationAndLegacyConus(t *testing.T) {
	service := &Service{}
	for _, raw := range []string{"", "_", "conus", " CONUS "} {
		selection, err := service.Normalize(Selection{Product: "aggregate", Station: raw})
		if err != nil {
			t.Fatalf("normalize %q: %v", raw, err)
		}
		if selection.Station != "conus" || selection.Elevation != "0.5" {
			t.Fatalf("normalize %q = %#v", raw, selection)
		}
	}
	selection, err := service.Normalize(Selection{Product: "aggregate", Station: "kgrk"})
	if err != nil {
		t.Fatal(err)
	}
	if selection.Station != "KGRK" {
		t.Fatalf("explicit aggregate station = %q", selection.Station)
	}
	for _, invalid := range []string{"K!!!", "TDFW", "ABC"} {
		if _, err := service.Normalize(Selection{Product: "aggregate", Station: invalid}); err == nil {
			t.Fatalf("invalid aggregate detail station %q was accepted", invalid)
		}
	}
}

func TestAggregateTileAddsExactLocalSuperResolutionDetailAtHighZoom(t *testing.T) {
	globalAnchor := time.Date(2026, 7, 14, 2, 20, 0, 0, time.UTC)
	localAnchor := globalAnchor.Add(10 * time.Minute)
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
		Selection{Product: "aggregate", Station: "KGRK", Elevation: "0.5"},
		Latest{
			ObservedAt: globalAnchor,
			Station:    "KGRK",
			Version:    "aggregate-generation",
			Components: map[string]LatestComponent{
				"alaska": {ObservedAt: globalAnchor},
				"conus":  {ObservedAt: localAnchor},
			},
			Detail: &AggregateDetail{
				Station:    "KGRK",
				ObservedAt: localAnchor,
				Latitude:   30.7218,
				Longitude:  -97.3828,
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
	if gotCatalogCalls != 0 {
		t.Fatalf("tile request performed %d station metadata calls", gotCatalogCalls)
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

func TestAggregatePinnedDetailPreservesRegionalBaseOutsideStationCoverage(t *testing.T) {
	anchor := time.Date(2026, 7, 14, 14, 34, 18, 0, time.UTC)
	basePNG := solidRadarPNG(t, color.NRGBA{R: 0x20, G: 0x21, B: 0x20, A: 0xff})
	var stationCalls atomic.Int32
	var baseCalls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.EqualFold(r.URL.Query().Get("request"), "GetMap") {
			http.Error(w, "tile rendering must not fetch metadata", http.StatusInternalServerError)
			return
		}
		if r.URL.Path == "/kgrk/ows" {
			stationCalls.Add(1)
			http.Error(w, "out-of-coverage station request", http.StatusInternalServerError)
			return
		}
		if r.URL.Path != "/conus/conus_bref_qcd/ows" {
			http.Error(w, "unexpected map endpoint", http.StatusBadRequest)
			return
		}
		baseCalls.Add(1)
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write(basePNG)
	}))
	defer server.Close()

	x, y := slippyTileForLocation(9, 40.7, -74)
	result, err := newAggregateDetailTestService(server).aggregateTile(
		context.Background(),
		Selection{Product: "aggregate", Station: "KGRK"},
		Latest{
			Station: "KGRK",
			Version: "pinned-kgrk-generation",
			Components: map[string]LatestComponent{
				"conus": {ObservedAt: anchor},
			},
			Detail: &AggregateDetail{Station: "KGRK", ObservedAt: anchor, Latitude: 30.7217, Longitude: -97.3828},
		},
		9,
		x,
		y,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(result.Value.Body, basePNG) {
		t.Fatal("out-of-coverage tile changed regional base")
	}
	if baseCalls.Load() != 1 || stationCalls.Load() != 0 {
		t.Fatalf("base/station calls = %d/%d", baseCalls.Load(), stationCalls.Load())
	}
}

func TestAggregateNationalOverviewCompositesExactRegionalGenerations(t *testing.T) {
	preservedRegionalColors := []color.NRGBA{
		{R: 0x54, G: 0xcf, B: 0xaa, A: 0xff}, // 16 dBZ
		{R: 0x28, G: 0xd6, B: 0x4a, A: 0xff}, // 20 dBZ
		{R: 0x0d, G: 0xb5, B: 0x12, A: 0xff}, // 24 dBZ
		{R: 0xf2, G: 0xc5, B: 0x1d, A: 0xff}, // 40 dBZ
		{R: 0xc5, G: 0x0a, B: 0x0b, A: 0xff}, // 50 dBZ
	}
	latest := Latest{
		Version:    "national-generation",
		Components: make(map[string]LatestComponent, len(aggregateRegions)),
	}
	regionPNGs := make(map[string][]byte, len(aggregateRegions))
	regionColors := make(map[string]color.NRGBA, len(aggregateRegions))
	for index, region := range aggregateRegions {
		observedAt := time.Date(2026, 7, 14, 2, index, 0, 0, time.UTC)
		latest.Components[region.name] = LatestComponent{ObservedAt: observedAt}
		value := preservedRegionalColors[index]
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

func TestAggregateNationalBaseCacheIsSharedAcrossDetailSelections(t *testing.T) {
	anchor := time.Date(2026, 7, 14, 14, 34, 18, 0, time.UTC)
	basePNG := solidRadarPNG(t, color.NRGBA{R: 0x20, G: 0x21, B: 0x20, A: 0xff})
	var mapCalls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.EqualFold(r.URL.Query().Get("request"), "GetMap") || r.URL.Path != "/conus/conus_bref_qcd/ows" {
			http.Error(w, "unexpected request", http.StatusBadRequest)
			return
		}
		mapCalls.Add(1)
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write(basePNG)
	}))
	defer server.Close()

	service := newAggregateDetailTestService(server)
	var firstBody []byte
	for _, detail := range []AggregateDetail{
		{Station: "KGRK", ObservedAt: anchor, Latitude: 30.7217, Longitude: -97.3828},
		{Station: "KSJT", ObservedAt: anchor.Add(-time.Minute), Latitude: 31.3711, Longitude: -100.4922},
	} {
		result, err := service.aggregateTile(
			context.Background(),
			Selection{Product: "aggregate", Station: detail.Station},
			Latest{
				Station: detail.Station,
				Version: detail.Station + "-detail-generation",
				Components: map[string]LatestComponent{
					"conus": {ObservedAt: anchor},
				},
				Detail: &detail,
			},
			0,
			0,
			0,
		)
		if err != nil {
			t.Fatal(err)
		}
		if firstBody == nil {
			firstBody = append([]byte(nil), result.Value.Body...)
		} else if !bytes.Equal(result.Value.Body, firstBody) {
			t.Fatal("national base changed with detail selection")
		}
	}
	if mapCalls.Load() != 1 {
		t.Fatalf("regional base map calls = %d, want shared cache hit", mapCalls.Load())
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
	var published atomic.Int32
	var capabilityCalls atomic.Int32
	var mapCalls atomic.Int32

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
			http.Error(w, "detail resolution must not fetch tiles", http.StatusInternalServerError)
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
	components := map[string]LatestComponent{
		"conus": {ObservedAt: anchorScan},
	}
	first, err := service.resolveAggregateDetail(context.Background(), "KGRK", components)
	if err != nil {
		t.Fatal(err)
	}
	if !first.ObservedAt.Equal(anchorScan) {
		t.Fatalf("first detail generation = %s, want %s", first.ObservedAt, anchorScan)
	}
	if capabilityCalls.Load() != 2 {
		t.Fatalf("capabilities calls = %d, want initial load plus forced refresh", capabilityCalls.Load())
	}

	// A newer station scan appearing upstream must not change an existing
	// aggregate generation or produce a second station tile cache entry.
	published.Store(2)
	second, err := service.resolveAggregateDetail(context.Background(), "KGRK", components)
	if err != nil {
		t.Fatal(err)
	}
	if !second.ObservedAt.Equal(anchorScan) {
		t.Fatalf("second detail generation = %s, want pinned %s", second.ObservedAt, anchorScan)
	}
	if capabilityCalls.Load() != 2 {
		t.Fatalf("capabilities calls after rollover = %d, want 2", capabilityCalls.Load())
	}
	if mapCalls.Load() != 0 {
		t.Fatalf("station GetMap calls during detail resolution = %d", mapCalls.Load())
	}
}

func TestAggregateConusHighZoomRemainsSeamlessRegionalBase(t *testing.T) {
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
		t.Fatal("conus high-zoom tile requested automatic station detail")
	default:
	}
}

func TestAggregatePinnedDetailUsesCallerTimeoutThenFallsBackToRegionalBase(t *testing.T) {
	anchor := time.Date(2026, 7, 14, 2, 30, 0, 0, time.UTC)
	basePNG := solidRadarPNG(t, color.NRGBA{R: 0x20, G: 0x21, B: 0x20, A: 0xff})
	stationStarted := make(chan struct{})
	var startOnce sync.Once
	var metadataCalls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch strings.ToLower(r.URL.Query().Get("request")) {
		case "getcapabilities":
			metadataCalls.Add(1)
			http.Error(w, "tile rendering must not fetch capabilities", http.StatusInternalServerError)
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

	ctx, cancel := context.WithTimeout(context.Background(), 75*time.Millisecond)
	defer cancel()
	startedAt := time.Now()
	result, err := newAggregateDetailTestService(server).aggregateTile(
		ctx,
		Selection{Product: "aggregate", Station: "KGRK", Elevation: "0.5"},
		Latest{
			Station: "KGRK",
			Version: "pinned-detail-generation",
			Components: map[string]LatestComponent{
				"conus": {ObservedAt: anchor},
			},
			Detail: &AggregateDetail{Station: "KGRK", ObservedAt: anchor, Latitude: 30.7218, Longitude: -97.3828},
		},
		9,
		116,
		210,
	)
	elapsed := time.Since(startedAt)
	if err != nil {
		t.Fatal(err)
	}
	if elapsed < 50*time.Millisecond {
		t.Fatalf("detail degraded before caller timeout: %s", elapsed)
	}
	if !bytes.Equal(result.Value.Body, basePNG) {
		t.Fatal("timed-out pinned detail did not return regional base")
	}
	if metadataCalls.Load() != 0 {
		t.Fatalf("tile rendering made %d metadata calls", metadataCalls.Load())
	}
	select {
	case <-stationStarted:
	default:
		t.Fatal("test did not reach pinned station tile")
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
		Selection{Product: "aggregate", Station: "KGRK", Elevation: "0.5"},
		Latest{
			Station: "KGRK",
			Version: "generation",
			Components: map[string]LatestComponent{
				"conus": {ObservedAt: anchor},
			},
			Detail: &AggregateDetail{Station: "KGRK", ObservedAt: anchor, Latitude: 30.7218, Longitude: -97.3828},
		},
		9,
		116,
		210,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(result.Value.Body, basePNG) {
		t.Fatal("malformed pinned station image did not fall back to regional data")
	}
}

func TestAggregateDetailRejectsStaleStationBeforeManifest(t *testing.T) {
	anchor := time.Date(2026, 7, 14, 2, 30, 0, 0, time.UTC)
	staleScan := anchor.Add(-30 * time.Minute)
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
			stationMapCalls.Add(1)
			http.Error(w, "stale detail must not fetch a tile", http.StatusInternalServerError)
		default:
			http.Error(w, "unexpected request", http.StatusBadRequest)
		}
	}))
	defer server.Close()

	service := newAggregateDetailTestService(server)
	_, err := service.resolveAggregateDetail(context.Background(), "KGRK", map[string]LatestComponent{
		"conus": {ObservedAt: anchor},
	})
	if err == nil {
		t.Fatal("stale station was accepted into aggregate generation")
	}
	if capabilityCalls.Load() != 2 {
		t.Fatalf("station capabilities calls = %d, want cached check plus refresh", capabilityCalls.Load())
	}
	if stationMapCalls.Load() != 0 {
		t.Fatalf("stale station GetMap calls = %d, want 0", stationMapCalls.Load())
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
		"",
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
		"",
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

func TestAggregateSignedSnapshotResolvesColdReplicaWithoutMetadataRefresh(t *testing.T) {
	firstObservation := time.Now().UTC().Truncate(time.Second).Add(-2 * time.Minute)
	secondObservation := firstObservation.Add(time.Minute)
	firstPNG := solidRadarPNG(t, color.NRGBA{R: 0x20, G: 0x21, B: 0x20, A: 0xff})
	secondPNG := solidRadarPNG(t, color.NRGBA{R: 0xff, A: 0xff})
	var rolledOver atomic.Bool
	var capabilityCalls atomic.Int32
	var mu sync.Mutex
	var mapTimes []string

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch strings.ToLower(r.URL.Query().Get("request")) {
		case "getcapabilities":
			capabilityCalls.Add(1)
			parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
			if len(parts) != 3 {
				http.Error(w, "unexpected capabilities endpoint", http.StatusBadRequest)
				return
			}
			observedAt := firstObservation
			if rolledOver.Load() {
				observedAt = secondObservation
			}
			writeRadarCapability(w, parts[1], observedAt, firstObservation, observedAt)
		case "getmap":
			requestedAt := r.URL.Query().Get("time")
			mu.Lock()
			mapTimes = append(mapTimes, r.URL.Query().Get("layers")+"="+requestedAt)
			mu.Unlock()
			w.Header().Set("Content-Type", "image/png")
			if requestedAt == firstObservation.Format(time.RFC3339) {
				_, _ = w.Write(firstPNG)
			} else {
				_, _ = w.Write(secondPNG)
			}
		default:
			http.Error(w, "unexpected request", http.StatusBadRequest)
		}
	}))
	defer server.Close()

	podA := newAggregateDetailTestService(server)
	firstLatest, err := podA.Latest(context.Background(), Selection{Product: "aggregate"})
	if err != nil {
		t.Fatal(err)
	}
	if firstLatest.GenerationToken == "" {
		t.Fatal("aggregate latest omitted signed generation token")
	}
	template, err := url.Parse(firstLatest.TileTemplate)
	if err != nil {
		t.Fatal(err)
	}
	if template.Query().Get("timestamp") != firstLatest.Version ||
		template.Query().Get("snapshot") != firstLatest.GenerationToken {
		t.Fatalf("aggregate tile template query = %q", template.RawQuery)
	}
	withMobileVersion, err := url.Parse(firstLatest.TileTemplate + "&v=" + firstLatest.Version)
	if err != nil {
		t.Fatal(err)
	}
	if withMobileVersion.Query().Get("snapshot") != firstLatest.GenerationToken ||
		len(withMobileVersion.String()) >= 512 {
		t.Fatalf("mobile tile URL lost snapshot or exceeded bound: %s", withMobileVersion)
	}

	rolledOver.Store(true)
	podB := newAggregateDetailTestService(server)
	// This reproduces the deployed failure: a cold second replica has never
	// remembered the opaque generation minted by pod A.
	_, err = podB.Tile(
		context.Background(),
		Selection{Product: "aggregate"},
		firstLatest.Version,
		"",
		0,
		0,
		0,
	)
	if !errors.Is(err, ErrInvalidGeneration) {
		t.Fatalf("legacy cross-replica request error = %v, want invalid generation", err)
	}
	callsAfterLegacyFailure := capabilityCalls.Load()
	if callsAfterLegacyFailure != int32(len(aggregateRegions)*2) {
		t.Fatalf("capability calls after two manifests = %d", callsAfterLegacyFailure)
	}

	result, err := podB.Tile(
		context.Background(),
		Selection{Product: "aggregate"},
		firstLatest.Version,
		firstLatest.GenerationToken,
		0,
		0,
		0,
	)
	if err != nil {
		t.Fatal(err)
	}
	if capabilityCalls.Load() != callsAfterLegacyFailure {
		t.Fatalf("signed snapshot triggered metadata lookup: %d -> %d", callsAfterLegacyFailure, capabilityCalls.Load())
	}
	rendered, err := png.Decode(bytes.NewReader(result.Value.Body))
	if err != nil {
		t.Fatal(err)
	}
	if got := color.NRGBAModel.Convert(rendered.At(0, 0)).(color.NRGBA); got != (color.NRGBA{R: 0x20, G: 0x21, B: 0x20, A: 0xff}) {
		t.Fatalf("cross-replica tile pixel = %#v, want old-generation bytes", got)
	}
	mu.Lock()
	gotMapTimes := append([]string(nil), mapTimes...)
	mu.Unlock()
	if len(gotMapTimes) != len(aggregateRegions) {
		t.Fatalf("signed national maps = %#v", gotMapTimes)
	}
	wantTime := firstObservation.Format(time.RFC3339)
	for _, requested := range gotMapTimes {
		if !strings.HasSuffix(requested, "="+wantTime) {
			t.Fatalf("signed national map = %q, want exact old time %q", requested, wantTime)
		}
	}
	tampered := firstLatest.GenerationToken[:len(firstLatest.GenerationToken)-1] + "A"
	if strings.HasSuffix(firstLatest.GenerationToken, "A") {
		tampered = firstLatest.GenerationToken[:len(firstLatest.GenerationToken)-1] + "B"
	}
	_, err = newAggregateDetailTestService(server).Tile(
		context.Background(),
		Selection{Product: "aggregate"},
		firstLatest.Version,
		tampered,
		0,
		0,
		0,
	)
	if !errors.Is(err, ErrInvalidGeneration) {
		t.Fatalf("tampered cross-replica snapshot error = %v", err)
	}
	if capabilityCalls.Load() != callsAfterLegacyFailure {
		t.Fatalf("tampered snapshot triggered metadata lookup")
	}
	mu.Lock()
	mapCount := len(mapTimes)
	mu.Unlock()
	if mapCount != len(aggregateRegions) {
		t.Fatalf("tampered snapshot triggered GetMap; count = %d", mapCount)
	}
}

func TestAggregateDetailSnapshotPinsExactStationScanAcrossColdReplicas(t *testing.T) {
	anchor := time.Now().UTC().Truncate(time.Second).Add(-2 * time.Minute)
	stationScan := anchor.Add(-3 * time.Minute)
	futureStationScan := anchor.Add(2 * time.Minute)
	basePNG := solidRadarPNG(t, color.NRGBA{R: 0x20, G: 0x21, B: 0x20, A: 0xff})
	detailColor := color.NRGBA{R: 0x28, G: 0xd6, B: 0x4a, A: 0xff}
	detailPNG := solidRadarPNG(t, detailColor)
	var metadataLocked atomic.Bool
	var metadataCalls atomic.Int32
	var mu sync.Mutex
	var mapRequests []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/stations" {
			metadataCalls.Add(1)
			if metadataLocked.Load() {
				http.Error(w, "cold tile must not fetch station catalog", http.StatusInternalServerError)
				return
			}
			w.Header().Set("Content-Type", "application/geo+json")
			_, _ = w.Write([]byte(aggregateDetailStationCatalog()))
			return
		}
		switch strings.ToLower(r.URL.Query().Get("request")) {
		case "getcapabilities":
			metadataCalls.Add(1)
			if metadataLocked.Load() {
				http.Error(w, "cold tile must not fetch capabilities", http.StatusInternalServerError)
				return
			}
			if r.URL.Path == "/kgrk/ows" {
				writeRadarCapability(w, "kgrk_sr_bref", futureStationScan, stationScan, futureStationScan)
				return
			}
			parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
			if len(parts) != 3 {
				http.Error(w, "unexpected capabilities endpoint", http.StatusBadRequest)
				return
			}
			writeRadarCapability(w, parts[1], anchor, anchor)
		case "getmap":
			requested := r.URL.Path + "=" + r.URL.Query().Get("time")
			mu.Lock()
			mapRequests = append(mapRequests, requested)
			mu.Unlock()
			w.Header().Set("Content-Type", "image/png")
			if r.URL.Path == "/conus/conus_bref_qcd/ows" {
				_, _ = w.Write(basePNG)
				return
			}
			if r.URL.Path == "/kgrk/ows" {
				_, _ = w.Write(detailPNG)
				return
			}
			http.Error(w, "unexpected map endpoint", http.StatusBadRequest)
		default:
			http.Error(w, "unexpected request", http.StatusBadRequest)
		}
	}))
	defer server.Close()

	issuer := newAggregateDetailTestService(server)
	latest, err := issuer.Latest(context.Background(), Selection{Product: "aggregate", Station: "KGRK"})
	if err != nil {
		t.Fatal(err)
	}
	if latest.Detail == nil || latest.Detail.Station != "KGRK" || !latest.Detail.ObservedAt.Equal(stationScan) {
		t.Fatalf("issued detail = %#v", latest.Detail)
	}
	payload := aggregateSnapshotPayload(t, latest.GenerationToken)
	if payload[0] != aggregateSnapshotSchemaV2 {
		t.Fatalf("detail snapshot schema = %d", payload[0])
	}
	callsAfterLatest := metadataCalls.Load()
	metadataLocked.Store(true)

	cold := newAggregateDetailTestService(server)
	result, err := cold.Tile(
		context.Background(),
		Selection{Product: "aggregate", Station: "KGRK"},
		latest.Version,
		latest.GenerationToken,
		9,
		116,
		210,
	)
	if err != nil {
		t.Fatal(err)
	}
	if metadataCalls.Load() != callsAfterLatest {
		t.Fatalf("cold replica metadata calls = %d -> %d", callsAfterLatest, metadataCalls.Load())
	}
	rendered, err := png.Decode(bytes.NewReader(result.Value.Body))
	if err != nil {
		t.Fatal(err)
	}
	if got := color.NRGBAModel.Convert(rendered.At(128, 128)).(color.NRGBA); got != detailColor {
		t.Fatalf("cold detail pixel = %#v", got)
	}

	mu.Lock()
	gotMaps := append([]string(nil), mapRequests...)
	mu.Unlock()
	if len(gotMaps) != 2 ||
		!containsString(gotMaps, "/conus/conus_bref_qcd/ows="+anchor.Format(time.RFC3339)) ||
		!containsString(gotMaps, "/kgrk/ows="+stationScan.Format(time.RFC3339)) {
		t.Fatalf("cold replica maps = %#v", gotMaps)
	}

	_, err = cold.Tile(
		context.Background(),
		Selection{Product: "aggregate", Station: "KSJT"},
		latest.Version,
		latest.GenerationToken,
		9,
		116,
		210,
	)
	if !errors.Is(err, ErrInvalidGeneration) {
		t.Fatalf("station path mismatch error = %v", err)
	}
	mu.Lock()
	mapCount := len(mapRequests)
	mu.Unlock()
	if mapCount != 2 || metadataCalls.Load() != callsAfterLatest {
		t.Fatal("station path tampering reached upstream")
	}
}

func TestAggregateSignedSnapshotExpiredCurrentFallbackAndReplayRejection(t *testing.T) {
	oldObservation := time.Now().UTC().Truncate(time.Second).Add(-tileGenerationGrace - time.Minute)
	currentObservation := time.Now().UTC().Truncate(time.Second)
	tilePNG := solidRadarPNG(t, color.NRGBA{R: 0x20, G: 0x21, B: 0x20, A: 0xff})
	var advanced atomic.Bool
	var mapCalls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch strings.ToLower(r.URL.Query().Get("request")) {
		case "getcapabilities":
			parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
			if len(parts) != 3 {
				http.Error(w, "unexpected capabilities endpoint", http.StatusBadRequest)
				return
			}
			observedAt := oldObservation
			if advanced.Load() {
				observedAt = currentObservation
			}
			writeRadarCapability(w, parts[1], observedAt, observedAt)
		case "getmap":
			mapCalls.Add(1)
			if got := r.URL.Query().Get("time"); got != oldObservation.Format(time.RFC3339) {
				t.Errorf("expired current generation map time = %q", got)
			}
			w.Header().Set("Content-Type", "image/png")
			_, _ = w.Write(tilePNG)
		default:
			http.Error(w, "unexpected request", http.StatusBadRequest)
		}
	}))
	defer server.Close()

	issuer := newAggregateDetailTestService(server)
	oldLatest, err := issuer.Latest(context.Background(), Selection{Product: "aggregate"})
	if err != nil {
		t.Fatal(err)
	}
	currentPod := newAggregateDetailTestService(server)
	if _, err := currentPod.Tile(
		context.Background(),
		Selection{Product: "aggregate"},
		oldLatest.Version,
		oldLatest.GenerationToken,
		8,
		58,
		105,
	); err != nil {
		t.Fatalf("expired but unchanged generation: %v", err)
	}
	if mapCalls.Load() != 1 {
		t.Fatalf("expired current map calls = %d, want 1", mapCalls.Load())
	}

	advanced.Store(true)
	coldAdvancedPod := newAggregateDetailTestService(server)
	_, err = coldAdvancedPod.Tile(
		context.Background(),
		Selection{Product: "aggregate"},
		oldLatest.Version,
		oldLatest.GenerationToken,
		8,
		58,
		105,
	)
	if !errors.Is(err, ErrInvalidGeneration) {
		t.Fatalf("expired replay after rollover error = %v, want invalid generation", err)
	}
	if mapCalls.Load() != 1 {
		t.Fatalf("expired replay fetched WMS tile; calls = %d", mapCalls.Load())
	}
}

func TestAggregateInvalidSignedSnapshotsDoNotTouchUpstream(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		http.Error(w, "must not be reached", http.StatusInternalServerError)
	}))
	defer server.Close()
	service := newAggregateDetailTestService(server)
	generation := strings.Repeat("a", 24)
	for index := 0; index < 32; index++ {
		_, err := service.Tile(
			context.Background(),
			Selection{Product: "aggregate"},
			generation,
			fmt.Sprintf("invalid-%d", index),
			8,
			58,
			105,
		)
		if !errors.Is(err, ErrInvalidGeneration) {
			t.Fatalf("invalid token %d error = %v", index, err)
		}
	}
	if calls.Load() != 0 {
		t.Fatalf("invalid signed snapshots triggered %d upstream calls", calls.Load())
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
		"",
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
	if len(gotMapTimes) != 1 {
		t.Fatalf("remembered conus generation maps = %#v, want regional base only", gotMapTimes)
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
		"",
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
		"",
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
	if mapCount != 2 {
		t.Fatalf("unknown generation triggered GetMap; map calls = %d", mapCount)
	}
}

func TestAggregatePinnedDetailIsConsistentAcrossFormerSanAntonioGridBoundaries(t *testing.T) {
	anchor := time.Date(2026, 7, 14, 14, 34, 18, 0, time.UTC)
	stationScan := anchor.Add(-2*time.Minute - 27*time.Second)
	basePNG := solidRadarPNG(t, color.NRGBA{R: 0x20, G: 0x21, B: 0x20, A: 0xff})
	detailColor := color.NRGBA{R: 0x28, G: 0xd6, B: 0x4a, A: 0xff}
	detailPNG := solidRadarPNG(t, detailColor)
	type request struct {
		path string
		time string
	}
	var mu sync.Mutex
	var requests []request
	var metadataCalls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch strings.ToLower(r.URL.Query().Get("request")) {
		case "getcapabilities":
			metadataCalls.Add(1)
			http.Error(w, "tile rendering must use pinned snapshot metadata", http.StatusInternalServerError)
		case "getmap":
			mu.Lock()
			requests = append(requests, request{path: r.URL.Path, time: r.URL.Query().Get("time")})
			mu.Unlock()
			w.Header().Set("Content-Type", "image/png")
			switch r.URL.Path {
			case "/conus/conus_bref_qcd/ows":
				_, _ = w.Write(basePNG)
			case "/kgrk/ows":
				_, _ = w.Write(detailPNG)
			default:
				http.Error(w, "unexpected station", http.StatusBadRequest)
			}
		default:
			http.Error(w, "unexpected request", http.StatusBadRequest)
		}
	}))
	defer server.Close()

	latest := Latest{
		Station: "KGRK",
		Version: "one-pinned-station-generation",
		Components: map[string]LatestComponent{
			"conus": {ObservedAt: anchor},
		},
		Detail: &AggregateDetail{Station: "KGRK", ObservedAt: stationScan, Latitude: 30.7217, Longitude: -97.3828},
	}
	service := newAggregateDetailTestService(server)
	for _, x := range []int{115, 116} {
		for _, y := range []int{211, 212} {
			result, err := service.aggregateTile(
				context.Background(),
				Selection{Product: "aggregate", Station: "KGRK", Elevation: "0.5"},
				latest,
				9,
				x,
				y,
			)
			if err != nil {
				t.Fatalf("tile %d/%d: %v", x, y, err)
			}
			rendered, err := png.Decode(bytes.NewReader(result.Value.Body))
			if err != nil {
				t.Fatal(err)
			}
			if got := color.NRGBAModel.Convert(rendered.At(128, 128)).(color.NRGBA); got != detailColor {
				t.Fatalf("tile %d/%d detail = %#v", x, y, got)
			}
		}
	}
	if metadataCalls.Load() != 0 {
		t.Fatalf("tile rendering made %d metadata calls", metadataCalls.Load())
	}
	mu.Lock()
	gotRequests := append([]request(nil), requests...)
	mu.Unlock()
	if len(gotRequests) != 8 {
		t.Fatalf("GetMap requests = %#v", gotRequests)
	}
	stationRequests := 0
	for _, got := range gotRequests {
		if got.path == "/kgrk/ows" {
			stationRequests++
			if got.time != stationScan.Format(time.RFC3339) {
				t.Fatalf("station scan = %q, want %q", got.time, stationScan.Format(time.RFC3339))
			}
		} else if got.path != "/conus/conus_bref_qcd/ows" {
			t.Fatalf("unexpected source %q", got.path)
		}
	}
	if stationRequests != 4 {
		t.Fatalf("station requests = %d, want one KGRK request per tile", stationRequests)
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

func TestAggregateDetailCoverageWrapsAcrossAntimeridian(t *testing.T) {
	for _, test := range []struct {
		name             string
		stationLongitude float64
		tileLongitude    float64
	}{
		{name: "west station east tile", stationLongitude: -176, tileLongitude: 179},
		{name: "east station west tile", stationLongitude: 176, tileLongitude: -179},
	} {
		t.Run(test.name, func(t *testing.T) {
			x, y := slippyTileForLocation(9, 52, test.tileLongitude)
			if !aggregateDetailIntersectsTile(AggregateDetail{
				Station:   "PABC",
				Latitude:  52,
				Longitude: test.stationLongitude,
			}, 9, x, y) {
				t.Fatalf("station at %g did not cover wrapped tile at %g", test.stationLongitude, test.tileLongitude)
			}
		})
	}
	x, y := slippyTileForLocation(9, 52, -150)
	if aggregateDetailIntersectsTile(AggregateDetail{Station: "PABC", Latitude: 52, Longitude: 176}, 9, x, y) {
		t.Fatal("distant Alaska tile incorrectly intersected station coverage")
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

func containsString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
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
		RadarBaseURL:      server.URL,
		AggregateTokenKey: "0123456789abcdef0123456789abcdef",
		StationsURL:       server.URL + "/stations",
		StationTTL:        time.Hour,
		MetadataTTL:       time.Minute,
		TileTTL:           time.Minute,
		RadarStaleAfter:   time.Hour,
		TileMaxZoom:       16,
		Reflectivity:      map[string]string{"0.5": "sr_bref"},
		Velocity:          map[string]string{"0.5": "sr_bvel"},
	}
	fetcher := upstream.NewFetcher(server.Client(), cache.New(128, 32<<20), "radar-test", 16<<20, time.Minute)
	return NewService(c, fetcher)
}
