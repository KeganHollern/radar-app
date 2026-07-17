package radar

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/draw"
	"image/png"
	"math"
	"sort"
	"strings"
	"time"

	"github.com/KeganHollern/radar-app/backend/internal/cache"
	"github.com/KeganHollern/radar-app/backend/internal/upstream"
)

const (
	// The regional MRMS mosaic is a 0.01 degree (roughly 1 km) grid. At zoom 9
	// and above, a slippy-map tile is local enough that NOAA's 0.00135 degree
	// station super-resolution product provides materially more spatial detail.
	// Keeping zoom 8 on the regional mosaic also avoids doubling the cold tile
	// load at the app's default regional startup zoom.
	aggregateDetailMinZoom = 9

	// At zoom 7 and above, each tile is geographically local enough to select
	// one US radar region without losing Alaska or Hawaii at a tile boundary.
	// Smaller zooms are composed from every available region so the full-country
	// overview remains intact and generation-pinned.
	aggregateRegionalBaseMinZoom = 7

	// NOAA advertises each station SR_BREF coverage as a square extending almost
	// exactly five degrees from its site. Keep a small tolerance for rounded WFS
	// station coordinates and WMS coverage bounds.
	stationCoverageRadiusDegrees = 5.05

	// A station volume scan normally updates within several minutes. Never lay
	// a much older station image over the current regional mosaic: this app is a
	// live view, and stale high-resolution precipitation is worse than retaining
	// the lower-resolution current base.
	aggregateDetailMaxLag = 10 * time.Minute

	// Derived tile keys include this revision so a presentation change never
	// reuses an older composite from a shared cache under the same radar scan.
	aggregatePresentationRevision = "reflectivity-floor-15-v1"
)

type aggregateDetailStation struct {
	id        string
	region    string
	latitude  float64
	longitude float64
}

type radarStationCatalog struct {
	Features []struct {
		Geometry struct {
			Type        string    `json:"type"`
			Coordinates []float64 `json:"coordinates"`
		} `json:"geometry"`
		Properties struct {
			ID string `json:"rda_id"`
		} `json:"properties"`
	} `json:"features"`
}

func (s *Service) aggregateTile(ctx context.Context, _ Selection, latest Latest, z, x, y int) (upstream.Result, error) {
	if z < aggregateDetailMinZoom || latest.Detail == nil {
		return s.fetchFilteredAggregateBaseTile(ctx, latest, z, x, y)
	}
	detail := *latest.Detail
	if !aggregateDetailIntersectsTile(detail, z, x, y) {
		return s.fetchFilteredAggregateBaseTile(ctx, latest, z, x, y)
	}

	type tileResponse struct {
		result upstream.Result
		err    error
	}
	fetchCtx, cancelFetch := context.WithCancel(ctx)
	defer cancelFetch()
	baseReady := make(chan tileResponse, 1)
	go func() {
		result, err := s.fetchFilteredAggregateBaseTile(fetchCtx, latest, z, x, y)
		baseReady <- tileResponse{result: result, err: err}
	}()
	detailReady := make(chan tileResponse, 1)
	go func() {
		selection := Selection{Product: "reflectivity", Station: detail.Station, Elevation: "0.5"}
		endpoint, layer := s.stationEndpointLayer(selection)
		query := pinnedWMSQuery(layer, tileBounds(z, x, y), detail.ObservedAt)
		target := endpoint + "?" + query.Encode()
		key := fmt.Sprintf(
			"tile:aggregate-station:%s:%d:%d:%d:%d",
			detail.Station,
			detail.ObservedAt.UnixNano(),
			z,
			x,
			y,
		)
		result, err := s.fetcher.Get(fetchCtx, key, target, "image/png", s.config.TileTTL, "image/png")
		detailReady <- tileResponse{result: result, err: err}
	}()

	base := <-baseReady
	if base.err != nil {
		return upstream.Result{}, base.err
	}
	station := <-detailReady
	if station.err != nil {
		return base.result, nil
	}

	compositeKey := fmt.Sprintf(
		"tile:aggregate-composite:%s:%s:%d:%d:%d",
		aggregatePresentationRevision,
		latest.Version,
		z,
		x,
		y,
	)
	result, err := s.fetcher.Derive(ctx, compositeKey, s.config.TileTTL, "image/png", func(context.Context) (upstream.Result, error) {
		filtered, err := filterStationReflectivityTile("reflectivity", station.result.Value.Body)
		if err != nil {
			return upstream.Result{}, err
		}
		composited, err := compositeRadarTiles(base.result.Value.Body, filtered)
		if err != nil {
			return upstream.Result{}, err
		}
		result := base.result
		result.Value.Body = composited
		result.Value.ETag = ""
		result.Value.LastModified = ""
		result.State = combinedCacheState(base.result.State, station.result.State)
		return result, nil
	})
	if err != nil {
		return base.result, nil
	}
	return result, nil
}

func (s *Service) fetchFilteredAggregateBaseTile(ctx context.Context, latest Latest, z, x, y int) (upstream.Result, error) {
	key := fmt.Sprintf(
		"tile:aggregate-filtered:%s:%s:%d:%d:%d",
		aggregatePresentationRevision,
		aggregateRegionalVersion(latest),
		z,
		x,
		y,
	)
	return s.fetcher.Derive(ctx, key, s.config.TileTTL, "image/png", func(buildCtx context.Context) (upstream.Result, error) {
		result, err := s.fetchAggregateBaseTile(buildCtx, latest, z, x, y)
		if err != nil {
			return upstream.Result{}, err
		}
		filtered, err := filterReflectivityTile(result.Value.Body)
		if err != nil {
			return upstream.Result{}, fmt.Errorf("filter aggregate reflectivity tile: %w", err)
		}
		result.Value.Body = filtered
		return result, nil
	})
}

func (s *Service) fetchAggregateBaseTile(ctx context.Context, latest Latest, z, x, y int) (upstream.Result, error) {
	if z < aggregateRegionalBaseMinZoom {
		return s.fetchNationalAggregateTile(ctx, latest, z, x, y)
	}

	regionName := aggregateRegionNameForTile(z, x, y)
	component, ok := latest.Components[regionName]
	if !ok || component.ObservedAt.IsZero() {
		return upstream.Result{}, fmt.Errorf("aggregate region %q has no observation", regionName)
	}
	region, ok := aggregateRegionNamed(regionName)
	if !ok {
		return upstream.Result{}, fmt.Errorf("aggregate region %q is unsupported", regionName)
	}
	endpoint := s.config.RadarBaseURL + "/" + region.workspace + "/ows"
	query := pinnedWMSQuery(region.layer, tileBounds(z, x, y), component.ObservedAt)
	target := endpoint + "?" + query.Encode()
	key := aggregateRegionalTileKey(regionName, component.ObservedAt, z, x, y)
	return s.fetcher.Get(ctx, key, target, "image/png", s.config.TileTTL, "image/png")
}

func (s *Service) fetchNationalAggregateTile(ctx context.Context, latest Latest, z, x, y int) (upstream.Result, error) {
	key := fmt.Sprintf("tile:aggregate-national:%s:%d:%d:%d", aggregateRegionalVersion(latest), z, x, y)
	return s.fetcher.Derive(ctx, key, s.config.TileTTL, "image/png", func(buildCtx context.Context) (upstream.Result, error) {
		type regionResponse struct {
			index  int
			result upstream.Result
			err    error
		}
		available := make([]int, 0, len(aggregateRegions))
		for index, region := range aggregateRegions {
			component, ok := latest.Components[region.name]
			if ok && !component.ObservedAt.IsZero() {
				available = append(available, index)
			}
		}
		if len(available) == 0 {
			return upstream.Result{}, errors.New("aggregate generation has no regional observations")
		}

		fetchCtx, cancel := context.WithCancel(buildCtx)
		defer cancel()
		responses := make(chan regionResponse, len(available))
		for _, index := range available {
			region := aggregateRegions[index]
			component := latest.Components[region.name]
			go func() {
				endpoint := s.config.RadarBaseURL + "/" + region.workspace + "/ows"
				query := pinnedWMSQuery(region.layer, tileBounds(z, x, y), component.ObservedAt)
				target := endpoint + "?" + query.Encode()
				key := aggregateRegionalTileKey(region.name, component.ObservedAt, z, x, y)
				result, err := s.fetcher.Get(fetchCtx, key, target, "image/png", s.config.TileTTL, "image/png")
				responses <- regionResponse{index: index, result: result, err: err}
			}()
		}

		results := make([]upstream.Result, len(aggregateRegions))
		for range available {
			response := <-responses
			if response.err != nil {
				cancel()
				return upstream.Result{}, response.err
			}
			results[response.index] = response.result
		}
		bodies := make([][]byte, 0, len(available))
		state := results[available[0]].State
		value := results[available[0]].Value
		for _, index := range available {
			bodies = append(bodies, results[index].Value.Body)
			state = combinedCacheState(state, results[index].State)
		}
		composited, err := compositeRadarTileSet(bodies)
		if err != nil {
			return upstream.Result{}, err
		}
		value.Body = composited
		value.ETag = ""
		value.LastModified = ""
		return upstream.Result{Value: value, State: state}, nil
	})
}

func aggregateRegionalVersion(latest Latest) string {
	observations := make(map[string]time.Time, len(latest.Components))
	missing := make([]string, 0, len(aggregateRegions))
	for _, region := range aggregateRegions {
		component, ok := latest.Components[region.name]
		if !ok || component.ObservedAt.IsZero() {
			missing = append(missing, region.name)
			continue
		}
		observations[region.name] = component.ObservedAt
	}
	sort.Strings(missing)
	return aggregateVersion(observations, missing)
}

func aggregateRegionalTileKey(regionName string, observedAt time.Time, z, x, y int) string {
	return fmt.Sprintf(
		"tile:aggregate-base:%s:%d:%d:%d:%d",
		regionName,
		observedAt.UnixMilli(),
		z,
		x,
		y,
	)
}

func (s *Service) resolveAggregateDetail(ctx context.Context, stationID string, components map[string]LatestComponent) (AggregateDetail, error) {
	catalog, err := s.fetcher.Get(
		ctx,
		"stations",
		s.config.StationsURL,
		"application/geo+json,application/json",
		s.config.StationTTL,
		"application/geo+json",
		"application/json",
	)
	if err != nil {
		return AggregateDetail{}, err
	}
	station, err := aggregateDetailStationNamed(catalog.Value.Body, stationID)
	if err != nil {
		return AggregateDetail{}, err
	}
	component, ok := components[station.region]
	if !ok || component.ObservedAt.IsZero() {
		return AggregateDetail{}, fmt.Errorf("station %s aggregate region %q has no observation", station.id, station.region)
	}

	selection := Selection{Product: "reflectivity", Station: station.id, Elevation: "0.5"}
	endpoint, layer := s.stationEndpointLayer(selection)
	latestStation, capabilities, err := s.fetchLatestLayer(ctx, endpoint, layer)
	if err != nil {
		return AggregateDetail{}, err
	}
	// A replica can have station capabilities cached from before the regional
	// anchor arrived. Refresh once before choosing an exact scan at/before it.
	if latestStation.Before(component.ObservedAt) {
		latestStation, capabilities, err = s.refreshLatestLayer(ctx, endpoint, layer)
		if err != nil {
			return AggregateDetail{}, err
		}
	}
	maxLag := aggregateDetailMaxLag
	if s.config.RadarStaleAfter < maxLag {
		maxLag = s.config.RadarStaleAfter
	}
	if latestStation.Before(component.ObservedAt) && component.ObservedAt.Sub(latestStation) > maxLag {
		return AggregateDetail{}, fmt.Errorf("station %s latest scan is %s behind aggregate", station.id, component.ObservedAt.Sub(latestStation).Round(time.Second))
	}
	observations, err := layerObservationTimes(capabilities.Value.Body, layer)
	if err != nil {
		return AggregateDetail{}, err
	}
	observedAt, ok := observationAtOrBefore(observations, component.ObservedAt)
	if !ok {
		return AggregateDetail{}, errors.New("station has no scan at or before the regional observation")
	}
	if component.ObservedAt.Sub(observedAt) > maxLag {
		return AggregateDetail{}, fmt.Errorf("station %s matching scan is %s behind aggregate", station.id, component.ObservedAt.Sub(observedAt).Round(time.Second))
	}
	return AggregateDetail{
		Station:    station.id,
		ObservedAt: observedAt,
		Latitude:   math.Round(station.latitude*aggregateCoordinateScale) / aggregateCoordinateScale,
		Longitude:  math.Round(station.longitude*aggregateCoordinateScale) / aggregateCoordinateScale,
	}, nil
}

func aggregateDetailStationNamed(body []byte, stationID string) (aggregateDetailStation, error) {
	var catalog radarStationCatalog
	if err := json.Unmarshal(body, &catalog); err != nil {
		return aggregateDetailStation{}, fmt.Errorf("decode radar stations: %w", err)
	}
	for _, feature := range catalog.Features {
		id := strings.ToUpper(strings.TrimSpace(feature.Properties.ID))
		if id != stationID || !supportedAggregateDetailStation(id) || feature.Geometry.Type != "Point" || len(feature.Geometry.Coordinates) < 2 {
			continue
		}
		longitude := feature.Geometry.Coordinates[0]
		latitude := feature.Geometry.Coordinates[1]
		if !validRadarCoordinate(latitude, longitude) {
			continue
		}
		return aggregateDetailStation{
			id:        id,
			region:    aggregateRegionForLocation(latitude, longitude),
			latitude:  latitude,
			longitude: longitude,
		}, nil
	}
	return aggregateDetailStation{}, fmt.Errorf("aggregate detail station %s is unavailable", stationID)
}

func validRadarCoordinate(latitude, longitude float64) bool {
	return !math.IsNaN(latitude) && !math.IsInf(latitude, 0) &&
		!math.IsNaN(longitude) && !math.IsInf(longitude, 0) &&
		latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180
}

func aggregateDetailIntersectsTile(detail AggregateDetail, z, x, y int) bool {
	bounds := geographicTileBounds(z, x, y)
	if bounds.maxY < detail.Latitude-stationCoverageRadiusDegrees ||
		bounds.minY > detail.Latitude+stationCoverageRadiusDegrees {
		return false
	}
	for _, shift := range []float64{-360, 0, 360} {
		longitude := detail.Longitude + shift
		if bounds.maxX >= longitude-stationCoverageRadiusDegrees &&
			bounds.minX <= longitude+stationCoverageRadiusDegrees {
			return true
		}
	}
	return false
}

func observationAtOrBefore(observations []time.Time, anchor time.Time) (time.Time, bool) {
	for index := len(observations) - 1; index >= 0; index-- {
		if !observations[index].After(anchor) {
			return observations[index], true
		}
	}
	return time.Time{}, false
}

func aggregateRegionForLocation(latitude, longitude float64) string {
	switch {
	case latitude > 50:
		return "alaska"
	case longitude > 120:
		return "guam"
	case latitude < 30 && longitude < -140:
		return "hawaii"
	case latitude < 25 && longitude > -70:
		return "caribbean"
	default:
		return "conus"
	}
}

func aggregateRegionNameForTile(z, x, y int) string {
	bounds := geographicTileBounds(z, x, y)
	return aggregateRegionForLocation(
		(bounds.minY+bounds.maxY)/2,
		(bounds.minX+bounds.maxX)/2,
	)
}

func aggregateRegionNamed(name string) (aggregateRegion, bool) {
	for _, region := range aggregateRegions {
		if region.name == name {
			return region, true
		}
	}
	return aggregateRegion{}, false
}

func supportedAggregateDetailStation(id string) bool {
	return len(id) == 4 && (id[0] == 'K' || id[0] == 'P' || id == "TJUA")
}

// geographicTileBounds uses the same Web Mercator tile convention as
// tileBounds, expressed in longitude/latitude for station-footprint tests.
func geographicTileBounds(z, x, y int) bounds {
	scale := math.Exp2(float64(z))
	west := float64(x)/scale*360 - 180
	east := float64(x+1)/scale*360 - 180
	north := math.Atan(math.Sinh(math.Pi*(1-2*float64(y)/scale))) * 180 / math.Pi
	south := math.Atan(math.Sinh(math.Pi*(1-2*float64(y+1)/scale))) * 180 / math.Pi
	return bounds{minX: west, minY: south, maxX: east, maxY: north}
}

func compositeRadarTiles(baseBody, overlayBody []byte) ([]byte, error) {
	return compositeRadarTileSet([][]byte{baseBody, overlayBody})
}

func compositeRadarTileSet(bodies [][]byte) ([]byte, error) {
	if len(bodies) == 0 {
		return nil, errors.New("no radar PNGs to composite")
	}
	var canvas *image.NRGBA
	for index, body := range bodies {
		layer, err := png.Decode(bytes.NewReader(body))
		if err != nil {
			return nil, fmt.Errorf("decode radar PNG layer %d: %w", index, err)
		}
		if canvas == nil {
			canvas = image.NewNRGBA(layer.Bounds())
		} else if !canvas.Bounds().Eq(layer.Bounds()) {
			return nil, fmt.Errorf("radar tile dimensions differ: %v and %v", canvas.Bounds(), layer.Bounds())
		}
		draw.Draw(canvas, canvas.Bounds(), layer, layer.Bounds().Min, draw.Over)
	}
	var output bytes.Buffer
	encoder := png.Encoder{CompressionLevel: png.BestSpeed}
	if err := encoder.Encode(&output, canvas); err != nil {
		return nil, fmt.Errorf("encode aggregate PNG: %w", err)
	}
	return output.Bytes(), nil
}

func combinedCacheState(first, second cache.State) cache.State {
	if first == cache.Stale || second == cache.Stale {
		return cache.Stale
	}
	if first == cache.Miss || second == cache.Miss {
		return cache.Miss
	}
	return cache.Hit
}
