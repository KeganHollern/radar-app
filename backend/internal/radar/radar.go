package radar

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/xml"
	"errors"
	"fmt"
	"math"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/KeganHollern/radar-app/backend/internal/config"
	"github.com/KeganHollern/radar-app/backend/internal/upstream"
)

const aggregateLayer = "conus_bref_qcd"

const aggregateTileLayers = "conus:conus_bref_qcd,alaska:alaska_bref_qcd,hawaii:hawaii_bref_qcd,carib:carib_bref_qcd,guam:guam_bref_qcd"

type Selection struct {
	Product   string
	Station   string
	Elevation string
}

type Latest struct {
	Product        string                     `json:"product"`
	Station        string                     `json:"station"`
	Elevation      string                     `json:"elevation"`
	ObservedAt     time.Time                  `json:"observedAt"`
	CheckedAt      time.Time                  `json:"checkedAt"`
	ReceivedAt     time.Time                  `json:"receivedAt"`
	AgeSeconds     int64                      `json:"ageSeconds"`
	Stale          bool                       `json:"stale"`
	Version        string                     `json:"version"`
	TileTemplate   string                     `json:"tileTemplate"`
	Source         string                     `json:"source"`
	Components     map[string]LatestComponent `json:"components,omitempty"`
	MissingRegions []string                   `json:"missingRegions,omitempty"`
}

type LatestComponent struct {
	ObservedAt time.Time `json:"observedAt"`
	CheckedAt  time.Time `json:"checkedAt"`
	AgeSeconds int64     `json:"ageSeconds"`
	Stale      bool      `json:"stale"`
}

type aggregateRegion struct {
	name      string
	workspace string
	layer     string
}

var aggregateRegions = []aggregateRegion{
	{name: "conus", workspace: "conus/conus_bref_qcd", layer: "conus_bref_qcd"},
	{name: "alaska", workspace: "alaska/alaska_bref_qcd", layer: "alaska_bref_qcd"},
	{name: "hawaii", workspace: "hawaii/hawaii_bref_qcd", layer: "hawaii_bref_qcd"},
	{name: "caribbean", workspace: "carib/carib_bref_qcd", layer: "carib_bref_qcd"},
	{name: "guam", workspace: "guam/guam_bref_qcd", layer: "guam_bref_qcd"},
}

type Service struct {
	config  config.Config
	fetcher *upstream.Fetcher
}

func NewService(c config.Config, fetcher *upstream.Fetcher) *Service {
	return &Service{config: c, fetcher: fetcher}
}

func (s *Service) Normalize(selection Selection) (Selection, error) {
	selection.Product = strings.ToLower(strings.TrimSpace(selection.Product))
	selection.Station = strings.ToUpper(strings.TrimSpace(selection.Station))
	selection.Elevation = strings.TrimSpace(selection.Elevation)
	if selection.Product == "" {
		selection.Product = "aggregate"
	}

	switch selection.Product {
	case "aggregate":
		selection.Station = "conus"
		selection.Elevation = "0.5"
		return selection, nil
	case "reflectivity", "velocity":
		if !validStation(selection.Station) {
			return Selection{}, errors.New("station must be a four-character radar site identifier")
		}
		layers := s.layers(selection.Product)
		if selection.Elevation == "" || selection.Elevation == "_" {
			selection.Elevation = firstElevation(layers)
		}
		if _, ok := layers[selection.Elevation]; !ok {
			return Selection{}, fmt.Errorf("elevation %q is not available for %s", selection.Elevation, selection.Product)
		}
		return selection, nil
	default:
		return Selection{}, errors.New("product must be aggregate, reflectivity, or velocity")
	}
}

func (s *Service) Tile(ctx context.Context, selection Selection, z, x, y int) (upstream.Result, error) {
	selection, err := s.Normalize(selection)
	if err != nil {
		return upstream.Result{}, err
	}
	if err := validateTile(z, x, y, s.config.TileMaxZoom); err != nil {
		return upstream.Result{}, err
	}
	// Resolve the current generation before reading a tile. The client-provided
	// timestamp is only a cache buster and is never forwarded; this manifest
	// lookup makes the server cache generation-aware without exposing history.
	latest, err := s.Latest(ctx, selection)
	if err != nil {
		return upstream.Result{}, err
	}
	endpoint, layer := s.tileEndpointLayer(selection)
	query := wmsQuery(layer, tileBounds(z, x, y))
	target := endpoint + "?" + query.Encode()
	key := fmt.Sprintf("tile:%s:%s:%s:%s:%d:%d:%d", selection.Product, selection.Station, selection.Elevation, latest.Version, z, x, y)
	result, err := s.fetcher.Get(ctx, key, target, "image/png", s.config.TileTTL, "image/png")
	if err != nil {
		return upstream.Result{}, err
	}
	filtered, err := filterStationReflectivityTile(selection.Product, result.Value.Body)
	if err != nil {
		return upstream.Result{}, fmt.Errorf("filter station reflectivity tile: %w", err)
	}
	result.Value.Body = filtered
	return result, nil
}

func (s *Service) Latest(ctx context.Context, selection Selection) (Latest, error) {
	selection, err := s.Normalize(selection)
	if err != nil {
		return Latest{}, err
	}
	if selection.Product == "aggregate" {
		return s.aggregateLatest(ctx, selection)
	}
	endpoint, layer := s.capabilitiesEndpointLayer(selection)
	observedAt, result, err := s.fetchLatestLayer(ctx, endpoint, layer)
	if err != nil {
		return Latest{}, err
	}
	return s.latestManifest(selection, observedAt, result, strconv.FormatInt(observedAt.UnixMilli(), 10)), nil
}

func (s *Service) fetchLatestLayer(ctx context.Context, endpoint, layer string) (time.Time, upstream.Result, error) {
	query := url.Values{
		"request": {"GetCapabilities"},
		"service": {"WMS"},
		"version": {"1.3.0"},
	}
	target := endpoint + "?" + query.Encode()
	key := "capabilities:" + endpoint + ":" + layer
	result, err := s.fetcher.Get(ctx, key, target, "application/xml,text/xml", s.config.MetadataTTL, "application/xml", "text/xml")
	if err != nil {
		return time.Time{}, upstream.Result{}, err
	}
	observedAt, err := latestLayerTime(result.Value.Body, layer)
	if err != nil {
		return time.Time{}, upstream.Result{}, err
	}
	return observedAt, result, nil
}

func (s *Service) latestManifest(selection Selection, observedAt time.Time, result upstream.Result, version string) Latest {
	now := time.Now().UTC()
	age := now.Sub(observedAt)
	if age < 0 {
		age = 0
	}
	template := fmt.Sprintf("%s/api/v1/radar/tiles/%s/%s/%s/{z}/{x}/{y}.png?timestamp=%s",
		s.config.PublicBaseURL, selection.Product, selection.Station, selection.Elevation, version)
	return Latest{
		Product:      selection.Product,
		Station:      selection.Station,
		Elevation:    selection.Elevation,
		ObservedAt:   observedAt,
		CheckedAt:    result.Value.CheckedAt,
		ReceivedAt:   result.Value.FetchedAt,
		AgeSeconds:   int64(age.Seconds()),
		Stale:        result.State == "STALE" || age > s.config.RadarStaleAfter,
		Version:      version,
		TileTemplate: template,
		Source:       "NOAA/NWS RIDGE II",
	}
}

func (s *Service) aggregateLatest(ctx context.Context, selection Selection) (Latest, error) {
	type regionResult struct {
		region     aggregateRegion
		observedAt time.Time
		result     upstream.Result
		err        error
	}
	results := make(chan regionResult, len(aggregateRegions))
	var wait sync.WaitGroup
	wait.Add(len(aggregateRegions))
	for _, region := range aggregateRegions {
		go func() {
			defer wait.Done()
			endpoint := s.config.RadarBaseURL + "/" + region.workspace + "/ows"
			observedAt, result, err := s.fetchLatestLayer(ctx, endpoint, region.layer)
			results <- regionResult{region: region, observedAt: observedAt, result: result, err: err}
		}()
	}
	wait.Wait()
	close(results)

	now := time.Now().UTC()
	components := make(map[string]LatestComponent, len(aggregateRegions))
	observations := make(map[string]time.Time, len(aggregateRegions))
	var oldest time.Time
	var representative upstream.Result
	missing := make([]string, 0)
	stale := false
	for item := range results {
		if item.err != nil {
			missing = append(missing, item.region.name)
			stale = true
			continue
		}
		age := now.Sub(item.observedAt)
		if age < 0 {
			age = 0
		}
		componentStale := item.result.State == "STALE" || age > s.config.RadarStaleAfter
		components[item.region.name] = LatestComponent{
			ObservedAt: item.observedAt,
			CheckedAt:  item.result.Value.CheckedAt,
			AgeSeconds: int64(age.Seconds()),
			Stale:      componentStale,
		}
		observations[item.region.name] = item.observedAt
		if oldest.IsZero() || item.observedAt.Before(oldest) {
			oldest = item.observedAt
			representative = item.result
		}
		stale = stale || componentStale
	}
	if oldest.IsZero() {
		return Latest{}, errors.New("all aggregate radar metadata providers are unavailable")
	}
	sort.Strings(missing)
	version := aggregateVersion(observations, missing)
	manifest := s.latestManifest(selection, oldest, representative, version)
	manifest.Stale = manifest.Stale || stale
	manifest.Components = components
	manifest.MissingRegions = missing
	return manifest, nil
}

func aggregateVersion(observations map[string]time.Time, missing []string) string {
	names := make([]string, 0, len(observations))
	for name := range observations {
		names = append(names, name)
	}
	sort.Strings(names)
	hash := sha256.New()
	for _, name := range names {
		_, _ = fmt.Fprintf(hash, "%s=%d;", name, observations[name].UnixMilli())
	}
	for _, name := range missing {
		_, _ = fmt.Fprintf(hash, "%s=missing;", name)
	}
	return hex.EncodeToString(hash.Sum(nil)[:12])
}

func (s *Service) Elevations(product string) []string {
	return sortedElevations(s.layers(product))
}

func (s *Service) tileEndpointLayer(selection Selection) (string, string) {
	if selection.Product == "aggregate" {
		return s.config.RadarBaseURL + "/ows", aggregateTileLayers
	}
	return s.stationEndpointLayer(selection)
}

func (s *Service) capabilitiesEndpointLayer(selection Selection) (string, string) {
	if selection.Product == "aggregate" {
		return s.config.RadarBaseURL + "/conus/conus_bref_qcd/ows", aggregateLayer
	}
	return s.stationEndpointLayer(selection)
}

func (s *Service) stationEndpointLayer(selection Selection) (string, string) {
	station := strings.ToLower(selection.Station)
	suffix := s.layers(selection.Product)[selection.Elevation]
	return s.config.RadarBaseURL + "/" + station + "/ows", station + "_" + suffix
}

func (s *Service) layers(product string) map[string]string {
	if product == "velocity" {
		return s.config.Velocity
	}
	return s.config.Reflectivity
}

func validStation(value string) bool {
	if len(value) != 4 {
		return false
	}
	for _, r := range value {
		if (r < 'A' || r > 'Z') && (r < '0' || r > '9') {
			return false
		}
	}
	return true
}

func firstElevation(layers map[string]string) string {
	elevations := sortedElevations(layers)
	if len(elevations) == 0 {
		return ""
	}
	return elevations[0]
}

func sortedElevations(layers map[string]string) []string {
	elevations := make([]string, 0, len(layers))
	for elevation := range layers {
		elevations = append(elevations, elevation)
	}
	sort.Slice(elevations, func(i, j int) bool {
		a, _ := strconv.ParseFloat(elevations[i], 64)
		b, _ := strconv.ParseFloat(elevations[j], 64)
		return a < b
	})
	return elevations
}

type bounds struct {
	minX float64
	minY float64
	maxX float64
	maxY float64
}

func validateTile(z, x, y, maxZoom int) error {
	if z < 0 || z > maxZoom {
		return fmt.Errorf("zoom must be between 0 and %d", maxZoom)
	}
	limit := 1 << z
	if x < 0 || y < 0 || x >= limit || y >= limit {
		return errors.New("tile coordinates are outside the zoom level")
	}
	return nil
}

func tileBounds(z, x, y int) bounds {
	origin := math.Pi * 6378137.0
	tileSize := (origin * 2) / float64(uint64(1)<<z)
	return bounds{
		minX: -origin + float64(x)*tileSize,
		minY: origin - float64(y+1)*tileSize,
		maxX: -origin + float64(x+1)*tileSize,
		maxY: origin - float64(y)*tileSize,
	}
}

func wmsQuery(layer string, b bounds) url.Values {
	return url.Values{
		"service":     {"WMS"},
		"version":     {"1.1.1"},
		"request":     {"GetMap"},
		"layers":      {layer},
		"styles":      {""},
		"format":      {"image/png"},
		"transparent": {"true"},
		"srs":         {"EPSG:3857"},
		"bbox":        {formatBounds(b)},
		"width":       {"256"},
		"height":      {"256"},
	}
}

func formatBounds(b bounds) string {
	values := []float64{b.minX, b.minY, b.maxX, b.maxY}
	parts := make([]string, len(values))
	for i, value := range values {
		parts[i] = strconv.FormatFloat(value, 'f', 6, 64)
	}
	return strings.Join(parts, ",")
}

type capabilities struct {
	Capability struct {
		Layer wmsLayer `xml:"Layer"`
	} `xml:"Capability"`
}

type wmsLayer struct {
	Name       string         `xml:"Name"`
	Dimensions []wmsDimension `xml:"Dimension"`
	Layers     []wmsLayer     `xml:"Layer"`
}

type wmsDimension struct {
	Name    string `xml:"name,attr"`
	Default string `xml:"default,attr"`
	Values  string `xml:",chardata"`
}

func latestLayerTime(body []byte, layerName string) (time.Time, error) {
	var document capabilities
	if err := xml.Unmarshal(body, &document); err != nil {
		return time.Time{}, fmt.Errorf("decode WMS capabilities: %w", err)
	}
	layer := findLayer(document.Capability.Layer, layerName)
	if layer == nil {
		return time.Time{}, fmt.Errorf("WMS layer %q is unavailable", layerName)
	}
	for _, dimension := range layer.Dimensions {
		if strings.EqualFold(dimension.Name, "time") {
			candidate := strings.TrimSpace(dimension.Default)
			if candidate == "" {
				values := strings.Split(strings.TrimSpace(dimension.Values), ",")
				candidate = strings.TrimSpace(values[len(values)-1])
			}
			observedAt, err := time.Parse(time.RFC3339Nano, candidate)
			if err != nil {
				return time.Time{}, fmt.Errorf("decode latest WMS observation time: %w", err)
			}
			return observedAt.UTC(), nil
		}
	}
	return time.Time{}, fmt.Errorf("WMS layer %q does not publish a latest observation time", layerName)
}

func findLayer(layer wmsLayer, name string) *wmsLayer {
	if layer.Name == name {
		return &layer
	}
	for i := range layer.Layers {
		if found := findLayer(layer.Layers[i], name); found != nil {
			return found
		}
	}
	return nil
}
