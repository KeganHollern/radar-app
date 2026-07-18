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
	if !c.LightningEnabled || c.LightningEastURL != "https://noaa-goes19.s3.amazonaws.com" || c.LightningWestURL != "https://noaa-goes18.s3.amazonaws.com" || c.LightningPoll.String() != "5s" || c.LightningRetention.String() != "1m30s" {
		t.Fatalf("unexpected lightning defaults: %#v", c)
	}
}

func TestLoadRejectsInvalidLightningConfiguration(t *testing.T) {
	tests := map[string]string{
		"RADAR_LIGHTNING_ENABLED":        "maybe",
		"RADAR_LIGHTNING_EAST_BASE_URL":  "http://noaa-goes19.s3.amazonaws.com",
		"RADAR_LIGHTNING_WEST_BASE_URL":  "https://attacker.example",
		"RADAR_LIGHTNING_POLL":           "0s",
		"RADAR_LIGHTNING_RETENTION":      "invalid",
		"RADAR_LIGHTNING_MAX_FLASHES":    "0",
		"RADAR_LIGHTNING_SEAM_LONGITUDE": "181",
	}
	for key, value := range tests {
		t.Run(key, func(t *testing.T) {
			t.Setenv("RADAR_AGGREGATE_TOKEN_KEY", "0123456789abcdef0123456789abcdef")
			t.Setenv(key, value)
			if _, err := Load(); err == nil {
				t.Fatalf("%s=%q unexpectedly accepted", key, value)
			}
		})
	}
}

func TestLoadRejectsLightningResourceAndPollingExtremes(t *testing.T) {
	tests := map[string]string{
		"RADAR_LIGHTNING_POLL":           "31s",
		"RADAR_LIGHTNING_RETENTION":      "20s",
		"RADAR_LIGHTNING_STALE_AFTER":    "1m",
		"RADAR_LIGHTNING_MAX_FLASHES":    "100001",
		"RADAR_LIGHTNING_MAX_OBJECT_MIB": "33",
	}
	for key, value := range tests {
		t.Run(key, func(t *testing.T) {
			t.Setenv("RADAR_AGGREGATE_TOKEN_KEY", "0123456789abcdef0123456789abcdef")
			t.Setenv(key, value)
			if _, err := Load(); err == nil {
				t.Fatalf("%s=%q unexpectedly accepted", key, value)
			}
		})
	}
	// Individually valid durations must still obey their relationship.
	t.Run("retention less than three polls", func(t *testing.T) {
		t.Setenv("RADAR_AGGREGATE_TOKEN_KEY", "0123456789abcdef0123456789abcdef")
		t.Setenv("RADAR_LIGHTNING_POLL", "30s")
		t.Setenv("RADAR_LIGHTNING_RETENTION", "60s")
		if _, err := Load(); err == nil {
			t.Fatal("unsafe poll/retention relationship unexpectedly accepted")
		}
	})
}

func TestLoadRejectsNonFiniteLightningSeam(t *testing.T) {
	for _, value := range []string{"NaN", "+Inf", "-Inf"} {
		t.Run(value, func(t *testing.T) {
			t.Setenv("RADAR_AGGREGATE_TOKEN_KEY", "0123456789abcdef0123456789abcdef")
			t.Setenv("RADAR_LIGHTNING_SEAM_LONGITUDE", value)
			if _, err := Load(); err == nil {
				t.Fatalf("non-finite seam %q unexpectedly accepted", value)
			}
		})
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
