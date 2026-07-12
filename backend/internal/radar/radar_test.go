package radar

import (
	"math"
	"strings"
	"testing"
	"time"

	"github.com/KeganHollern/radar-app/backend/internal/config"
)

func TestTileBounds(t *testing.T) {
	b := tileBounds(0, 0, 0)
	want := math.Pi * 6378137
	if math.Abs(b.minX+want) > 0.001 || math.Abs(b.maxY-want) > 0.001 || math.Abs(b.maxX-want) > 0.001 || math.Abs(b.minY+want) > 0.001 {
		t.Fatalf("unexpected world bounds: %#v", b)
	}
}

func TestWMSQueryRequestsTransparentPNG(t *testing.T) {
	query := wmsQuery("kdmx_sr_bref", tileBounds(7, 30, 47))
	if got := query.Get("format"); got != "image/png" {
		t.Fatalf("format = %q, want image/png", got)
	}
	if got := query.Get("transparent"); got != "true" {
		t.Fatalf("transparent = %q, want true", got)
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
		"conus":  time.Unix(100, 0),
		"alaska": time.Unix(200, 0),
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
}

func TestLatestLayerTime(t *testing.T) {
	body := []byte(`<WMS_Capabilities><Capability><Layer><Layer><Name>kfws_sr_bref</Name><Dimension name="time" default="2026-07-12T20:10:00Z">ignored</Dimension></Layer></Layer></Capability></WMS_Capabilities>`)
	got, err := latestLayerTime(body, "kfws_sr_bref")
	if err != nil {
		t.Fatal(err)
	}
	want := time.Date(2026, 7, 12, 20, 10, 0, 0, time.UTC)
	if !got.Equal(want) {
		t.Fatalf("got %s want %s", got, want)
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
