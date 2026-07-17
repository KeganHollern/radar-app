package radar

import (
	"bytes"
	"context"
	"image"
	"image/color"
	"image/png"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

var (
	weakTenDBZColor      = color.NRGBA{R: 0x54, G: 0x8f, B: 0xbd, A: 0xff}
	weakFourteenDBZColor = color.NRGBA{R: 0x59, G: 0xbe, B: 0xbc, A: 0xff}
	thresholdDBZColor    = color.NRGBA{R: 0x57, G: 0xc7, B: 0xb3, A: 0xff}
	strongDBZColor       = color.NRGBA{R: 0x28, G: 0xd6, B: 0x4a, A: 0xff}
	unknownRadarColor    = color.NRGBA{R: 0x10, G: 0x10, B: 0x10, A: 0xff}
)

func TestAggregateRegionalBaseUsesSharedReflectivityFloor(t *testing.T) {
	anchor := time.Date(2026, 7, 17, 12, 0, 0, 0, time.UTC)
	basePNG := aggregateFilterPNG(t, []color.NRGBA{
		weakTenDBZColor,
		weakFourteenDBZColor,
		thresholdDBZColor,
		strongDBZColor,
		unknownRadarColor,
	})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.EqualFold(r.URL.Query().Get("request"), "GetMap") || r.URL.Path != "/conus/conus_bref_qcd/ows" {
			http.Error(w, "unexpected request", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write(basePNG)
	}))
	defer server.Close()

	result, err := newAggregateDetailTestService(server).aggregateTile(
		context.Background(),
		Selection{Product: "aggregate", Station: "conus"},
		Latest{
			Version: "filtered-regional-generation",
			Components: map[string]LatestComponent{
				"conus": {ObservedAt: anchor},
			},
		},
		7,
		29,
		52,
	)
	if err != nil {
		t.Fatal(err)
	}
	assertAggregateReflectivityFloor(t, result.Value.Body)
}

func TestAggregateDetailCompositionCannotRevealWeakRegionalBase(t *testing.T) {
	anchor := time.Date(2026, 7, 17, 12, 0, 0, 0, time.UTC)
	basePNG := aggregateFilterPNG(t, []color.NRGBA{
		weakTenDBZColor,
		weakFourteenDBZColor,
		weakTenDBZColor,
		thresholdDBZColor,
		unknownRadarColor,
	})
	detailPNG := aggregateFilterPNG(t, []color.NRGBA{
		{},
		weakTenDBZColor,
		strongDBZColor,
		{},
		{},
	})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.EqualFold(r.URL.Query().Get("request"), "GetMap") {
			http.Error(w, "unexpected request", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "image/png")
		switch r.URL.Path {
		case "/conus/conus_bref_qcd/ows":
			_, _ = w.Write(basePNG)
		case "/kgrk/ows":
			_, _ = w.Write(detailPNG)
		default:
			http.Error(w, "unexpected map endpoint", http.StatusBadRequest)
		}
	}))
	defer server.Close()

	result, err := newAggregateDetailTestService(server).aggregateTile(
		context.Background(),
		Selection{Product: "aggregate", Station: "KGRK"},
		Latest{
			Station: "KGRK",
			Version: "filtered-detail-generation",
			Components: map[string]LatestComponent{
				"conus": {ObservedAt: anchor},
			},
			Detail: &AggregateDetail{
				Station:    "KGRK",
				ObservedAt: anchor,
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

	rendered := decodeAggregateFilterPNG(t, result.Value.Body)
	assertTransparentPixel(t, rendered, 0)
	assertTransparentPixel(t, rendered, 1)
	assertAggregateFilterPixel(t, rendered, 2, strongDBZColor)
	assertAggregateFilterPixel(t, rendered, 3, thresholdDBZColor)
	assertAggregateFilterPixel(t, rendered, 4, unknownRadarColor)
}

func TestAggregateDetailFailureFallsBackToFilteredRegionalBase(t *testing.T) {
	anchor := time.Date(2026, 7, 17, 12, 0, 0, 0, time.UTC)
	basePNG := aggregateFilterPNG(t, []color.NRGBA{
		weakTenDBZColor,
		weakFourteenDBZColor,
		thresholdDBZColor,
		strongDBZColor,
		unknownRadarColor,
	})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.EqualFold(r.URL.Query().Get("request"), "GetMap") {
			http.Error(w, "unexpected request", http.StatusBadRequest)
			return
		}
		switch r.URL.Path {
		case "/conus/conus_bref_qcd/ows":
			w.Header().Set("Content-Type", "image/png")
			_, _ = w.Write(basePNG)
		case "/kgrk/ows":
			http.Error(w, "station unavailable", http.StatusBadGateway)
		default:
			http.Error(w, "unexpected map endpoint", http.StatusBadRequest)
		}
	}))
	defer server.Close()

	result, err := newAggregateDetailTestService(server).aggregateTile(
		context.Background(),
		Selection{Product: "aggregate", Station: "KGRK"},
		Latest{
			Station: "KGRK",
			Version: "filtered-fallback-generation",
			Components: map[string]LatestComponent{
				"conus": {ObservedAt: anchor},
			},
			Detail: &AggregateDetail{
				Station:    "KGRK",
				ObservedAt: anchor,
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
	assertAggregateReflectivityFloor(t, result.Value.Body)
}

func TestAggregateNationalCompositeUsesSharedReflectivityFloor(t *testing.T) {
	anchor := time.Date(2026, 7, 17, 12, 0, 0, 0, time.UTC)
	colors := []color.NRGBA{
		weakTenDBZColor,
		weakFourteenDBZColor,
		thresholdDBZColor,
		strongDBZColor,
		unknownRadarColor,
	}
	latest := Latest{
		Version:    "filtered-national-generation",
		Components: make(map[string]LatestComponent, len(aggregateRegions)),
	}
	regionPNGs := make(map[string][]byte, len(aggregateRegions))
	for index, region := range aggregateRegions {
		latest.Components[region.name] = LatestComponent{ObservedAt: anchor.Add(time.Duration(index) * time.Second)}
		pixels := make([]color.NRGBA, len(aggregateRegions))
		pixels[index] = colors[index]
		regionPNGs[region.layer] = aggregateFilterPNG(t, pixels)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.EqualFold(r.URL.Query().Get("request"), "GetMap") {
			http.Error(w, "unexpected request", http.StatusBadRequest)
			return
		}
		body, ok := regionPNGs[r.URL.Query().Get("layers")]
		if !ok {
			http.Error(w, "unexpected regional layer", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write(body)
	}))
	defer server.Close()

	result, err := newAggregateDetailTestService(server).aggregateTile(
		context.Background(),
		Selection{Product: "aggregate", Station: "conus"},
		latest,
		0,
		0,
		0,
	)
	if err != nil {
		t.Fatal(err)
	}
	rendered := decodeAggregateFilterPNG(t, result.Value.Body)
	assertTransparentPixel(t, rendered, 0)
	assertTransparentPixel(t, rendered, 1)
	assertAggregateFilterPixel(t, rendered, 2, thresholdDBZColor)
	assertAggregateFilterPixel(t, rendered, 3, strongDBZColor)
	assertAggregateFilterPixel(t, rendered, 4, unknownRadarColor)
}

func aggregateFilterPNG(t *testing.T, pixels []color.NRGBA) []byte {
	t.Helper()
	source := image.NewNRGBA(image.Rect(0, 0, len(pixels), 1))
	for x, pixel := range pixels {
		source.SetNRGBA(x, 0, pixel)
	}
	return encodePNG(t, source)
}

func decodeAggregateFilterPNG(t *testing.T, body []byte) image.Image {
	t.Helper()
	rendered, err := png.Decode(bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	return rendered
}

func assertAggregateReflectivityFloor(t *testing.T, body []byte) {
	t.Helper()
	rendered := decodeAggregateFilterPNG(t, body)
	assertTransparentPixel(t, rendered, 0)
	assertTransparentPixel(t, rendered, 1)
	assertAggregateFilterPixel(t, rendered, 2, thresholdDBZColor)
	assertAggregateFilterPixel(t, rendered, 3, strongDBZColor)
	assertAggregateFilterPixel(t, rendered, 4, unknownRadarColor)
}

func assertTransparentPixel(t *testing.T, rendered image.Image, x int) {
	t.Helper()
	_, _, _, alpha := rendered.At(x, 0).RGBA()
	if alpha != 0 {
		t.Fatalf("pixel %d alpha = %d, want transparent", x, alpha)
	}
}

func assertAggregateFilterPixel(t *testing.T, rendered image.Image, x int, want color.NRGBA) {
	t.Helper()
	if got := color.NRGBAModel.Convert(rendered.At(x, 0)).(color.NRGBA); got != want {
		t.Fatalf("pixel %d = %#v, want %#v", x, got, want)
	}
}
