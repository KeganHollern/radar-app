package config

import "testing"

func TestLoadDefaults(t *testing.T) {
	t.Setenv("RADAR_AGGREGATE_TOKEN_KEY", "0123456789abcdef0123456789abcdef")
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if c.ListenAddr != ":8080" || c.Reflectivity["0.5"] != "sr_bref" || c.Velocity["0.5"] != "sr_bvel" {
		t.Fatalf("unexpected defaults: %#v", c)
	}
}

func TestLoadRejectsInvalidLayers(t *testing.T) {
	t.Setenv("RADAR_AGGREGATE_TOKEN_KEY", "0123456789abcdef0123456789abcdef")
	t.Setenv("RADAR_REFLECTIVITY_LAYERS", "0.5:sr_bref,1.5:../../secret")
	if _, err := Load(); err == nil {
		t.Fatal("expected invalid layer error")
	}
}

func TestLoadRequiresStrongAggregateTokenKey(t *testing.T) {
	t.Setenv("RADAR_AGGREGATE_TOKEN_KEY", "too-short")
	if _, err := Load(); err == nil {
		t.Fatal("expected short aggregate token key to be rejected")
	}
}
