package config

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	defaultNWSBaseURL   = "https://api.weather.gov"
	defaultRadarBaseURL = "https://opengeo.ncep.noaa.gov/geoserver"
	defaultStationsURL  = "https://opengeo.ncep.noaa.gov/geoserver/nws/ows?request=GetFeature&service=WFS&typeName=nws%3Aradar_sites&version=1.0.0&outputFormat=application%2Fjson"
)

type Config struct {
	ListenAddr       string
	PublicBaseURL    string
	NWSBaseURL       string
	RadarBaseURL     string
	StationsURL      string
	UserAgent        string
	AllowedOrigins   []string
	UpstreamTimeout  time.Duration
	ShutdownTimeout  time.Duration
	AlertTTL         time.Duration
	AlertZoneTTL     time.Duration
	AlertZoneTimeout time.Duration
	AlertZoneFailTTL time.Duration
	AlertZoneMax     int
	AlertZoneWorkers int
	StationTTL       time.Duration
	TileTTL          time.Duration
	MetadataTTL      time.Duration
	RadarStaleAfter  time.Duration
	StaleTTL         time.Duration
	UpdatePoll       time.Duration
	CacheMaxEntries  int
	CacheMaxBytes    int64
	MaxUpstreamBytes int64
	TileMaxZoom      int
	Reflectivity     map[string]string
	Velocity         map[string]string
}

func Load() (Config, error) {
	c := Config{
		ListenAddr:       env("RADAR_LISTEN_ADDR", ":8080"),
		PublicBaseURL:    strings.TrimRight(env("RADAR_PUBLIC_BASE_URL", "https://radar.lystic.dev"), "/"),
		NWSBaseURL:       strings.TrimRight(env("RADAR_NWS_BASE_URL", defaultNWSBaseURL), "/"),
		RadarBaseURL:     strings.TrimRight(env("RADAR_WMS_BASE_URL", defaultRadarBaseURL), "/"),
		StationsURL:      env("RADAR_STATIONS_URL", defaultStationsURL),
		UserAgent:        env("RADAR_USER_AGENT", "radar.lystic.dev/1.0 (+https://radar.lystic.dev)"),
		AllowedOrigins:   splitCSV(env("RADAR_ALLOWED_ORIGINS", "*")),
		UpstreamTimeout:  duration("RADAR_UPSTREAM_TIMEOUT", 8*time.Second),
		ShutdownTimeout:  duration("RADAR_SHUTDOWN_TIMEOUT", 10*time.Second),
		AlertTTL:         duration("RADAR_ALERT_TTL", 30*time.Second),
		AlertZoneTTL:     duration("RADAR_ALERT_ZONE_TTL", 24*time.Hour),
		AlertZoneTimeout: duration("RADAR_ALERT_ZONE_TIMEOUT", 3*time.Second),
		AlertZoneFailTTL: duration("RADAR_ALERT_ZONE_FAILURE_TTL", time.Minute),
		AlertZoneMax:     integer("RADAR_ALERT_ZONE_MAX_FETCHES", 64),
		AlertZoneWorkers: integer("RADAR_ALERT_ZONE_CONCURRENCY", 8),
		StationTTL:       duration("RADAR_STATION_TTL", 24*time.Hour),
		TileTTL:          duration("RADAR_TILE_TTL", 20*time.Second),
		MetadataTTL:      duration("RADAR_METADATA_TTL", 15*time.Second),
		RadarStaleAfter:  duration("RADAR_STALE_AFTER", 15*time.Minute),
		StaleTTL:         duration("RADAR_STALE_TTL", 10*time.Minute),
		UpdatePoll:       duration("RADAR_UPDATE_POLL", 15*time.Second),
		CacheMaxEntries:  integer("RADAR_CACHE_MAX_ENTRIES", 2048),
		CacheMaxBytes:    int64(integer("RADAR_CACHE_MAX_MIB", 128)) << 20,
		MaxUpstreamBytes: int64(integer("RADAR_MAX_UPSTREAM_MIB", 16)) << 20,
		TileMaxZoom:      integer("RADAR_TILE_MAX_ZOOM", 16),
		Reflectivity:     layerMap("RADAR_REFLECTIVITY_LAYERS", "0.5:sr_bref"),
		Velocity:         layerMap("RADAR_VELOCITY_LAYERS", "0.5:sr_bvel"),
	}

	if c.ListenAddr == "" || c.UserAgent == "" {
		return Config{}, errors.New("RADAR_LISTEN_ADDR and RADAR_USER_AGENT must not be empty")
	}
	if c.UpstreamTimeout <= 0 || c.ShutdownTimeout <= 0 || c.AlertTTL <= 0 || c.AlertZoneTTL <= 0 || c.AlertZoneTimeout <= 0 || c.AlertZoneFailTTL <= 0 || c.StationTTL <= 0 || c.TileTTL <= 0 || c.MetadataTTL <= 0 || c.RadarStaleAfter <= 0 || c.StaleTTL <= 0 || c.UpdatePoll <= 0 {
		return Config{}, errors.New("timeouts and cache TTLs must be positive")
	}
	if c.AlertZoneMax < 1 || c.AlertZoneWorkers < 1 || c.AlertZoneWorkers > c.AlertZoneMax {
		return Config{}, errors.New("alert zone concurrency must be positive and no greater than the fetch limit")
	}
	if c.CacheMaxEntries < 1 || c.CacheMaxBytes < 1 || c.MaxUpstreamBytes < 1 {
		return Config{}, errors.New("cache and response limits must be positive")
	}
	if c.TileMaxZoom < 0 || c.TileMaxZoom > 24 {
		return Config{}, errors.New("RADAR_TILE_MAX_ZOOM must be between 0 and 24")
	}
	if len(c.Reflectivity) == 0 || len(c.Velocity) == 0 {
		return Config{}, errors.New("each station radar product must have at least one elevation layer")
	}
	return c, nil
}

func env(key, fallback string) string {
	if value, ok := os.LookupEnv(key); ok {
		return strings.TrimSpace(value)
	}
	return fallback
}

func duration(key string, fallback time.Duration) time.Duration {
	value, ok := os.LookupEnv(key)
	if !ok || strings.TrimSpace(value) == "" {
		return fallback
	}
	parsed, err := time.ParseDuration(strings.TrimSpace(value))
	if err != nil {
		return -1
	}
	return parsed
}

func integer(key string, fallback int) int {
	value, ok := os.LookupEnv(key)
	if !ok || strings.TrimSpace(value) == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil {
		return -1
	}
	return parsed
}

func splitCSV(raw string) []string {
	var result []string
	for _, item := range strings.Split(raw, ",") {
		if item = strings.TrimSpace(item); item != "" {
			result = append(result, item)
		}
	}
	return result
}

func layerMap(key, fallback string) map[string]string {
	raw := env(key, fallback)
	result := make(map[string]string)
	for _, item := range splitCSV(raw) {
		parts := strings.SplitN(item, ":", 2)
		if len(parts) != 2 {
			return nil
		}
		elevation := strings.TrimSpace(parts[0])
		layer := strings.ToLower(strings.TrimSpace(parts[1]))
		if !validElevation(elevation) || !validLayer(layer) {
			return nil
		}
		result[elevation] = layer
	}
	return result
}

func validElevation(value string) bool {
	degrees, err := strconv.ParseFloat(value, 64)
	return err == nil && degrees >= -0.2 && degrees <= 20
}

func validLayer(value string) bool {
	if value == "" {
		return false
	}
	for _, r := range value {
		if (r < 'a' || r > 'z') && (r < '0' || r > '9') && r != '_' {
			return false
		}
	}
	return true
}

func (c Config) String() string {
	return fmt.Sprintf("listen=%s radar=%s nws=%s", c.ListenAddr, c.RadarBaseURL, c.NWSBaseURL)
}
