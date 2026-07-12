package api

import (
	"encoding/json"
	"math"
	"testing"
)

func TestSimplifyRingStronglyReducesAndPreservesClosure(t *testing.T) {
	original := denseCircle(-100, 35, 1, 2000)
	simplified := simplifyRing(original, zoneSimplifyToleranceDegrees)
	if len(simplified) >= len(original)/10 {
		t.Fatalf("ring was not materially reduced: original=%d simplified=%d", len(original), len(simplified))
	}
	if !validRing(simplified) {
		t.Fatalf("simplified ring is invalid: %#v", simplified)
	}
	if !positionsEqual(simplified[0], simplified[len(simplified)-1]) {
		t.Fatal("simplified ring is not closed")
	}
	if len(simplified) < 4 {
		t.Fatalf("simplified ring has only %d vertices", len(simplified))
	}
}

func TestSimplifyPolygonPreservesHolesAndBounds(t *testing.T) {
	value := polygon{
		denseCircle(-100, 35, 1, 1000),
		denseCircle(-100, 35, 0.25, 500),
	}
	simplified := simplifyPolygon(value, zoneSimplifyToleranceDegrees)
	if len(simplified) != 2 {
		t.Fatalf("rings = %d, want exterior and hole", len(simplified))
	}
	if !validPolygon(simplified) {
		t.Fatal("simplified polygon with hole is invalid")
	}
	for _, ring := range simplified {
		for _, point := range ring {
			if point[0] < -101 || point[0] > -99 || point[1] < 34 || point[1] > 36 {
				t.Fatalf("simplifier created an out-of-bounds point: %#v", point)
			}
		}
	}
}

func TestEnrichAlertsDoesNotSimplifyInlineGeometry(t *testing.T) {
	ring := denseCircle(-100, 35, 1, 500)
	body, err := json.Marshal(map[string]any{
		"type": "FeatureCollection",
		"features": []any{map[string]any{
			"type": "Feature",
			"geometry": map[string]any{
				"type":        "Polygon",
				"coordinates": polygon{ring},
			},
			"properties": map[string]any{"event": "Tornado Warning", "severity": "Extreme"},
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	server := &Server{}
	result, err := server.enrichAlerts(t.Context(), body)
	if err != nil {
		t.Fatal(err)
	}
	feature, properties, geometry := decodeSingleAlert(t, result)
	if feature["geometry"] == nil || properties["radarGeometrySimplified"] != nil {
		t.Fatalf("inline geometry was marked as simplified: %#v", feature)
	}
	coordinates := geometry["coordinates"].([]any)
	outputRing := coordinates[0].([]any)
	if len(outputRing) != len(ring) {
		t.Fatalf("inline ring changed from %d to %d points", len(ring), len(outputRing))
	}
}

func denseCircle(longitude, latitude, radius float64, points int) linearRing {
	ring := make(linearRing, 0, points+1)
	for i := 0; i < points; i++ {
		angle := 2 * math.Pi * float64(i) / float64(points)
		ring = append(ring, position{longitude + radius*math.Cos(angle), latitude + radius*math.Sin(angle)})
	}
	ring = append(ring, ring[0])
	return ring
}
