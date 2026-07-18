package lightning

import (
	"testing"
	"time"
)

func TestParseObjectKeyRequiresExactCurrentProduct(t *testing.T) {
	key := "GLM-L2-LCFA/2026/199/16/OR_GLM-L2-LCFA_G19_s20261991626400_e20261991627000_c20261991627017.nc"
	object, err := ParseObjectKey(key, "G19")
	if err != nil {
		t.Fatal(err)
	}
	if object.Satellite != "G19" || !object.Start.Equal(time.Date(2026, 7, 18, 16, 26, 40, 0, time.UTC)) || !object.End.Equal(time.Date(2026, 7, 18, 16, 27, 0, 0, time.UTC)) {
		t.Fatalf("unexpected object: %#v", object)
	}
	for _, test := range []struct {
		key       string
		satellite string
	}{
		{key, "G18"},
		{"GLM-L2-LCFA/2026/198/16/OR_GLM-L2-LCFA_G19_s20261991626400_e20261991627000_c20261991627017.nc", "G19"},
		{"GLM-L2-LCFA/2026/199/16/OR_GLM-L2-LCFA_G19_s20261991626400_e20261991628000_c20261991628017.nc", "G19"},
		{"GLM-L2-LCFA/2026/199/16/not-a-product.nc", "G19"},
	} {
		if _, err := ParseObjectKey(test.key, test.satellite); err == nil {
			t.Errorf("ParseObjectKey(%q, %q) unexpectedly succeeded", test.key, test.satellite)
		}
	}
}

func TestParseGOESTimeRejectsNonLeapDay366(t *testing.T) {
	if _, err := parseGOESTime("20253660000000"); err == nil {
		t.Fatal("non-leap day 366 unexpectedly accepted")
	}
	if parsed, err := parseGOESTime("20243660000000"); err != nil || parsed.Month() != time.December || parsed.Day() != 31 {
		t.Fatalf("valid leap timestamp = %v, %v", parsed, err)
	}
}
