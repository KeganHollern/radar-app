package config

import "testing"

func TestLoadDefaults(t *testing.T) {
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if c.ListenAddr != ":8080" || c.Reflectivity["0.5"] != "sr_bref" || c.Velocity["0.5"] != "sr_bvel" {
		t.Fatalf("unexpected defaults: %#v", c)
	}
}

func TestLoadRejectsInvalidLayers(t *testing.T) {
	t.Setenv("RADAR_REFLECTIVITY_LAYERS", "0.5:sr_bref,1.5:../../secret")
	if _, err := Load(); err == nil {
		t.Fatal("expected invalid layer error")
	}
}
