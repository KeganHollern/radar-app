package lightning

import (
	"math"
	"testing"
	"time"
)

func TestParseBoundsAndAntimeridianContainment(t *testing.T) {
	bounds, err := ParseBounds("170,-20,-170,20")
	if err != nil {
		t.Fatal(err)
	}
	for _, point := range []struct {
		latitude  float64
		longitude float64
	}{{0, 175}, {0, -175}, {20, 180}} {
		if !bounds.Contains(point.latitude, point.longitude) {
			t.Fatalf("expected bounds to contain %#v", point)
		}
	}
	if bounds.Contains(0, 0) {
		t.Fatal("antimeridian bounds unexpectedly contain longitude zero")
	}

	validUS, err := ParseBounds("-170,5,-45,65")
	if err != nil || !validUS.Contains(30, -100) {
		t.Fatalf("standard US view was rejected: %v", err)
	}
	for _, invalid := range []string{
		"-180,-90,180,90",
		"-170,-45,10,45",
		"-100,30,-100,40",
		"-100,40,-90,30",
		"NaN,20,-90,40",
		"-181,20,-90,40",
		"-100,20,-90",
	} {
		if _, err := ParseBounds(invalid); err == nil {
			t.Errorf("ParseBounds(%q) unexpectedly succeeded", invalid)
		}
	}
}

func TestServiceRetainsDeduplicatesBoundsAndSignals(t *testing.T) {
	now := time.Date(2026, 7, 18, 17, 0, 0, 0, time.UTC)
	service := NewService(ServiceOptions{Retention: 90 * time.Second, StaleAfter: 90 * time.Second, MaxFlashes: 2})
	updates, cancel := service.Subscribe()
	defer cancel()

	batch := Batch{
		Source:    EastSourceID,
		ObjectKey: "object-one",
		ObjectEnd: now.Add(-5 * time.Second),
		Flashes: []Flash{
			{ID: "oldest", Latitude: 30, Longitude: -100, ObservedAt: now.Add(-20 * time.Second), Satellite: "GOES-19"},
			{ID: "middle", Latitude: 35, Longitude: -95, ObservedAt: now.Add(-10 * time.Second), Satellite: "GOES-19"},
			{ID: "newest", Latitude: 40, Longitude: -90, ObservedAt: now.Add(-5 * time.Second), Satellite: "GOES-19"},
		},
	}
	if !service.Ingest(batch, now) {
		t.Fatal("fresh batch was not ingested")
	}
	select {
	case <-updates:
	default:
		t.Fatal("ingest did not signal subscribers")
	}
	if service.Ingest(batch, now) {
		t.Fatal("duplicate source object was ingested")
	}
	service.MarkChecked("G19", now)
	eastBounds, _ := ParseBounds("-104,20,-80,50")
	snapshot := service.Snapshot(eastBounds, now)
	if !snapshot.Available || snapshot.Stale || snapshot.ObservedAt == nil || snapshot.CheckedAt == nil {
		t.Fatalf("unexpected live metadata: %#v", snapshot)
	}
	if len(snapshot.Data.Features) != 2 || snapshot.Data.Features[0].ID != "middle" || snapshot.Data.Features[1].ID != "newest" {
		t.Fatalf("bounded flashes = %#v", snapshot.Data.Features)
	}
	if snapshot.Data.Features[0].Properties.Kind != FlashKind || snapshot.Data.Features[0].Geometry.Coordinates != [2]float64{-95, 35} {
		t.Fatalf("unexpected feature contract: %#v", snapshot.Data.Features[0])
	}

	bounds, _ := ParseBounds("-97,32,-93,37")
	filtered := service.Snapshot(bounds, now)
	if len(filtered.Data.Features) != 1 || filtered.Data.Features[0].ID != "middle" {
		t.Fatalf("filtered flashes = %#v", filtered.Data.Features)
	}

	previousGeneration := snapshot.Generation
	if !service.Ingest(Batch{Source: EastSourceID, ObjectKey: "clear-scan", ObjectEnd: now.Add(5 * time.Second)}, now.Add(5*time.Second)) {
		t.Fatal("zero-flash scan was not ingested")
	}
	clearSnapshot := service.Snapshot(eastBounds, now.Add(5*time.Second))
	if clearSnapshot.Generation == previousGeneration || clearSnapshot.ObservedAt == nil || !clearSnapshot.ObservedAt.Equal(now.Add(5*time.Second)) || clearSnapshot.Stale {
		t.Fatalf("zero-flash scan did not advance live state: %#v", clearSnapshot)
	}

	expired := service.Snapshot(eastBounds, now.Add(2*time.Minute))
	if len(expired.Data.Features) != 0 || !expired.Stale {
		t.Fatalf("expired snapshot = %#v", expired)
	}
}

func TestServiceRejectsStaleOrInvalidBatches(t *testing.T) {
	now := time.Date(2026, 7, 18, 17, 0, 0, 0, time.UTC)
	service := NewService(ServiceOptions{Retention: time.Minute})
	for _, batch := range []Batch{
		{},
		{Source: EastSourceID, ObjectKey: "stale", ObjectEnd: now.Add(-time.Minute)},
		{Source: EastSourceID, ObjectKey: "future", ObjectEnd: now.Add(time.Minute)},
	} {
		if service.Ingest(batch, now) {
			t.Fatalf("invalid batch was ingested: %#v", batch)
		}
	}
}

func TestServiceFreshnessTracksSuccessfulChecksDuringCalmWeatherAndOutage(t *testing.T) {
	now := time.Date(2026, 7, 18, 17, 0, 0, 0, time.UTC)
	service := NewService(ServiceOptions{Retention: 90 * time.Second, StaleAfter: 90 * time.Second})
	service.Ingest(Batch{Source: EastSourceID, ObjectKey: "calm-scan", ObjectEnd: now}, now)
	service.MarkChecked("G19", now)
	eastBounds, _ := ParseBounds("-104,20,-60,60")

	// A decoded product containing zero flashes is healthy product progress.
	calm := service.Snapshot(eastBounds, now.Add(30*time.Second))
	if !calm.Available || calm.Stale || len(calm.Data.Features) != 0 {
		t.Fatalf("calm zero-flash product = %#v", calm)
	}

	// Repeated successful bucket listings cannot make a frozen product fresh.
	service.MarkChecked("G19", now.Add(2*time.Minute))
	frozen := service.Snapshot(eastBounds, now.Add(2*time.Minute))
	if !frozen.Available || !frozen.Stale || frozen.CheckedAt == nil || !frozen.CheckedAt.Equal(now.Add(2*time.Minute)) {
		t.Fatalf("empty listings masked frozen product: %#v", frozen)
	}

	// The next successfully decoded, still-empty product restores freshness.
	service.Ingest(Batch{Source: EastSourceID, ObjectKey: "next-calm-scan", ObjectEnd: now.Add(2 * time.Minute)}, now.Add(2*time.Minute))
	calm = service.Snapshot(eastBounds, now.Add(2*time.Minute))
	if !calm.Available || calm.Stale || calm.ObservedAt == nil || !calm.ObservedAt.Equal(now.Add(2*time.Minute)) {
		t.Fatalf("new calm product did not restore freshness: %#v", calm)
	}

	stale := service.Snapshot(eastBounds, now.Add(3*time.Minute+31*time.Second))
	if !stale.Available || !stale.Stale {
		t.Fatalf("outage did not transition to stale: %#v", stale)
	}
	unavailable := service.Snapshot(eastBounds, now.Add(5*time.Minute+1*time.Second))
	if unavailable.Available || !unavailable.Stale {
		t.Fatalf("long outage did not transition to unavailable: %#v", unavailable)
	}
}

func TestServiceHealthUsesOnlyBBoxRelevantSatelliteProgress(t *testing.T) {
	start := time.Date(2026, 7, 18, 17, 0, 0, 0, time.UTC)
	service := NewService(ServiceOptions{Retention: 90 * time.Second, StaleAfter: 90 * time.Second, SeamLongitude: -105})
	service.Ingest(Batch{Source: EastSourceID, ObjectKey: "east-old", ObjectEnd: start}, start)
	service.Ingest(Batch{Source: WestSourceID, ObjectKey: "west-old", ObjectEnd: start}, start)

	now := start.Add(100 * time.Second)
	service.Ingest(Batch{Source: EastSourceID, ObjectKey: "east-current", ObjectEnd: now}, now)
	service.MarkChecked(EastSourceID, now)
	service.MarkChecked(WestSourceID, now)
	east, _ := ParseBounds("-100,20,-60,60")
	west, _ := ParseBounds("-150,20,-110,60")
	combined, _ := ParseBounds("-120,20,-90,60")
	antimeridian, _ := ParseBounds("170,-20,-170,20")

	eastSnapshot := service.Snapshot(east, now)
	if !eastSnapshot.Available || eastSnapshot.Stale || eastSnapshot.ObservedAt == nil || !eastSnapshot.ObservedAt.Equal(now) {
		t.Fatalf("fresh east bbox inherited west health: %#v", eastSnapshot)
	}
	westSnapshot := service.Snapshot(west, now)
	if !westSnapshot.Available || !westSnapshot.Stale || westSnapshot.ObservedAt == nil || !westSnapshot.ObservedAt.Equal(start) {
		t.Fatalf("frozen west bbox was masked by east: %#v", westSnapshot)
	}
	for name, bounds := range map[string]*Bounds{"combined": combined, "antimeridian": antimeridian} {
		snapshot := service.Snapshot(bounds, now)
		if !snapshot.Available || !snapshot.Stale || snapshot.ObservedAt == nil || !snapshot.ObservedAt.Equal(start) {
			t.Errorf("%s bbox did not use oldest required product: %#v", name, snapshot)
		}
	}

	later := start.Add(181 * time.Second)
	if snapshot := service.Snapshot(east, later); !snapshot.Available || snapshot.Stale {
		t.Fatalf("east should remain independently healthy: %#v", snapshot)
	}
	if snapshot := service.Snapshot(west, later); snapshot.Available || !snapshot.Stale {
		t.Fatalf("west should become unavailable independently: %#v", snapshot)
	}
	if snapshot := service.Snapshot(combined, later); snapshot.Available || !snapshot.Stale {
		t.Fatalf("combined status was masked by east: %#v", snapshot)
	}
}

func TestServiceMissingSatelliteCannotBeMaskedByOtherFeed(t *testing.T) {
	now := time.Date(2026, 7, 18, 17, 0, 0, 0, time.UTC)
	service := NewService(ServiceOptions{SeamLongitude: -105})
	service.Ingest(Batch{Source: EastSourceID, ObjectKey: "east", ObjectEnd: now}, now)
	service.MarkChecked(EastSourceID, now)
	east, _ := ParseBounds("-100,20,-60,60")
	combined, _ := ParseBounds("-120,20,-90,60")
	if snapshot := service.Snapshot(east, now); !snapshot.Available || snapshot.Stale {
		t.Fatalf("east-only bbox should be healthy: %#v", snapshot)
	}
	if snapshot := service.Snapshot(combined, now); snapshot.Available || snapshot.ObservedAt != nil || snapshot.CheckedAt != nil {
		t.Fatalf("missing west feed was masked by east: %#v", snapshot)
	}
}

func TestServiceDatelineAndPositiveLongitudesUseWestSatellite(t *testing.T) {
	now := time.Date(2026, 7, 18, 17, 0, 0, 0, time.UTC)
	service := NewService(ServiceOptions{SeamLongitude: -105})
	service.Ingest(Batch{Source: WestSourceID, ObjectKey: "west", ObjectEnd: now}, now)
	service.MarkChecked(WestSourceID, now)
	positive, _ := ParseBounds("160,20,175,60")
	antimeridian, _ := ParseBounds("170,-20,-170,20")
	for name, bounds := range map[string]*Bounds{"positive": positive, "antimeridian": antimeridian} {
		snapshot := service.Snapshot(bounds, now)
		if !snapshot.Available || snapshot.Stale || snapshot.ObservedAt == nil || !snapshot.ObservedAt.Equal(now) {
			t.Errorf("%s bbox did not use GOES-18-only health: %#v", name, snapshot)
		}
	}
}

func TestDirectServicesDefaultInvalidSeam(t *testing.T) {
	now := time.Date(2026, 7, 18, 17, 0, 0, 0, time.UTC)
	service := NewService(ServiceOptions{SeamLongitude: math.NaN()})
	service.Ingest(Batch{Source: EastSourceID, ObjectKey: "east", ObjectEnd: now}, now)
	east, _ := ParseBounds("-100,20,-60,60")
	if snapshot := service.Snapshot(east, now); !snapshot.Available {
		t.Fatalf("NaN seam did not default safely: %#v", snapshot)
	}
	decoder := NetCDFDecoder{SeamLongitude: math.Inf(1)}
	if !decoder.belongsToSatellite(EastSourceID, -100) || decoder.belongsToSatellite(EastSourceID, 170) {
		t.Fatal("non-finite decoder seam did not default to the supported partition")
	}
}
