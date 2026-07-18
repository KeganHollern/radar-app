package lightning

import (
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/batchatco/go-native-netcdf/netcdf"
	netcdfapi "github.com/batchatco/go-native-netcdf/netcdf/api"
	"github.com/batchatco/go-native-netcdf/netcdf/util"
)

func TestDecodeRowsFiltersQualityAndOwnsOneSideOfSeam(t *testing.T) {
	start := time.Date(2026, 7, 18, 16, 28, 40, 0, time.UTC)
	object := Object{Key: "test-object", Satellite: "G19", Start: start, End: start.Add(20 * time.Second)}
	decoder := NetCDFDecoder{SeamLongitude: -105}
	rows := rowValues{
		ids:            []int16{1, 2, 3, 4, 5},
		latitudes:      []float32{30, 31, 32, 33, 34},
		longitudes:     []float32{-100, -99, -110, -98, 170},
		qualities:      []int16{0, 3, 0, 0, 0},
		offsets:        []int16{0, 0, 0, -1, 0},
		baseTime:       start,
		scale:          20.0 / 65535.0,
		addOffset:      0,
		unsignedOffset: true,
		unsignedID:     true,
	}
	flashes := decoder.decodeRows(object, start.Add(21*time.Second), rows)
	if len(flashes) != 2 {
		t.Fatalf("got %d flashes, want 2: %#v", len(flashes), flashes)
	}
	if flashes[0].Longitude != -100 || flashes[0].ObservedAt != start {
		t.Fatalf("first flash = %#v", flashes[0])
	}
	if flashes[1].Longitude != -98 || flashes[1].ObservedAt.Before(start.Add(19*time.Second)) {
		t.Fatalf("unsigned wrapped offset was not decoded: %#v", flashes[1])
	}
	if flashes[0].ID == flashes[1].ID || flashes[0].Satellite != "GOES-19" || flashes[0].ID != stableFlashID("G19", "test-object", 1) {
		t.Fatalf("unstable identity or satellite label: %#v", flashes)
	}

	west := NetCDFDecoder{SeamLongitude: -105}.decodeRows(Object{Key: "west", Satellite: "G18", Start: start, End: start.Add(20 * time.Second)}, start, rows)
	if len(west) != 2 || west[0].Longitude != -110 || west[1].Longitude != 170 {
		t.Fatalf("west seam flashes = %#v", west)
	}
}

func TestUnsignedNumericAndTimeHelpers(t *testing.T) {
	if value, ok := numericAt([]int16{-1}, 0, true); !ok || value != 65535 {
		t.Fatalf("unsigned int16 = %v, %v", value, ok)
	}
	if value, ok := numericAt([]int16{-1}, 0, false); !ok || value != -1 {
		t.Fatalf("signed int16 = %v, %v", value, ok)
	}
	parsed, err := parseNetCDFBaseTime("2026-07-18 16:28:40.000")
	if err != nil || !parsed.Equal(time.Date(2026, 7, 18, 16, 28, 40, 0, time.UTC)) {
		t.Fatalf("base time = %v, %v", parsed, err)
	}
	if _, err := (NetCDFDecoder{}).Decode([]byte("not-netcdf"), Object{}, time.Now()); err == nil {
		t.Fatal("malformed NetCDF unexpectedly decoded")
	}
}

func TestNormalizeLongitudeRejectsImplausibleFiniteValueInConstantTime(t *testing.T) {
	if normalized := normalizeLongitude(math.MaxFloat64); !math.IsNaN(normalized) {
		t.Fatalf("MaxFloat64 normalized to %v, want rejection", normalized)
	}
	if normalized := normalizeLongitude(359); normalized != -1 {
		t.Fatalf("359 normalized to %v, want -1", normalized)
	}
}

func TestDecodeTinyNetCDFLCFAFixture(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tiny-lcfa.nc")
	writer, err := netcdf.OpenWriter(path, netcdf.KindHDF5)
	if err != nil {
		t.Fatal(err)
	}
	attributes := func(keys []string, values map[string]any) netcdfapi.AttributeMap {
		t.Helper()
		result, err := util.NewOrderedMap(keys, values)
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	add := func(name string, values any, attrs netcdfapi.AttributeMap) {
		t.Helper()
		if err := writer.AddVar(name, netcdfapi.Variable{Values: values, Dimensions: []string{"number_of_flashes"}, Attributes: attrs}); err != nil {
			_ = writer.Close()
			t.Fatalf("add %s: %v", name, err)
		}
	}
	unsignedAttrs := attributes(
		[]string{"valid_range"},
		map[string]any{"valid_range": []int16{0, -2}},
	)
	add("flash_id", []int16{1, 2, 3, 4, 5}, unsignedAttrs)
	add("flash_lat", []float32{30, 31, 32, 70, 33}, attributes(
		[]string{"valid_range"},
		map[string]any{"valid_range": []float32{-60, 60}},
	))
	add("flash_lon", []float32{-100, -99, -98, -97, 170}, attributes(
		[]string{"valid_range"},
		map[string]any{"valid_range": []float32{-180, 180}},
	))
	add("flash_quality_flag", []int16{0, 3, 0, 0, 0}, attributes(
		[]string{"valid_range"},
		map[string]any{"valid_range": []int16{0, 5}},
	))
	// NOAA's packed offsets are unsigned shorts sometimes stored without the
	// _Unsigned marker. Row one proves the negative int16 is reinterpreted;
	// row three proves an out-of-range packed sentinel is rejected.
	add("flash_time_offset_of_last_event", []int16{-32768, 0, -1, 0, 0}, attributes(
		[]string{"units", "scale_factor", "add_offset", "valid_range"},
		map[string]any{
			"units":        "seconds since 2026-07-18 16:28:40.000",
			"scale_factor": float32(20.0 / 65535.0),
			"add_offset":   float32(0),
			"valid_range":  []int16{0, -2},
		},
	))
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	start := time.Date(2026, 7, 18, 16, 28, 40, 0, time.UTC)
	object := Object{Key: "tiny-lcfa", Satellite: EastSourceID, Start: start, End: start.Add(20 * time.Second)}
	flashes, err := (NetCDFDecoder{MaxFlashes: 10, SeamLongitude: -105}).Decode(body, object, start.Add(21*time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if len(flashes) != 1 {
		t.Fatalf("decoded flashes = %#v", flashes)
	}
	if flashes[0].ID != stableFlashID(EastSourceID, object.Key, 1) || flashes[0].Longitude != -100 || flashes[0].ObservedAt.Before(start.Add(9*time.Second)) || flashes[0].ObservedAt.After(start.Add(11*time.Second)) {
		t.Fatalf("decoded flash = %#v", flashes[0])
	}
}

func TestValidatedNumericRejectsFillValueAndInvalidRange(t *testing.T) {
	attrs, err := util.NewOrderedMap(
		[]string{"_FillValue", "valid_range"},
		map[string]any{"_FillValue": int16(-1), "valid_range": []int16{0, -2}},
	)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := validatedNumericAt([]int16{-1}, attrs, 0, true); ok {
		t.Fatal("raw fill value was accepted after unsigned reinterpretation")
	}
	if _, ok := validatedNumericAt([]int16{-2}, attrs, 0, true); !ok {
		t.Fatal("valid unsigned upper bound was rejected")
	}
	malformed, _ := util.NewOrderedMap([]string{"valid_range"}, map[string]any{"valid_range": []int16{0}})
	if _, ok := validatedNumericAt([]int16{0}, malformed, 0, true); ok {
		t.Fatal("malformed valid_range was accepted")
	}
}
