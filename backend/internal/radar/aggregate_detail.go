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

	// Select one station for every zoom-7 parent tile. Children of the same
	// parent therefore use the same radar and exact scan, which avoids a visible
	// source seam when adjacent high-zoom tiles are requested independently.
	aggregateDetailSelectionZoom = 7

	// NOAA advertises each station SR_BREF coverage as a square extending almost
	// exactly five degrees from its site. Keep a small tolerance for rounded WFS
	// station coordinates and WMS coverage bounds.
	stationCoverageRadiusDegrees = 5.05

	// Station detail is optional enrichment. A slow station endpoint must not
	// hold an otherwise ready regional tile for the full upstream timeout.
	aggregateDetailTimeout = 2 * time.Second

	// A station volume scan normally updates within several minutes. Never lay
	// a much older station image over the current regional mosaic: this app is a
	// live view, and stale high-resolution precipitation is worse than retaining
	// the lower-resolution current base.
	aggregateDetailMaxLag = 10 * time.Minute
)

type aggregateDetailStation struct {
	id       string
	region   string
	distance float64
}

type aggregateStationDetail struct {
	station    aggregateDetailStation
	observedAt time.Time
	result     upstream.Result
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
	if z < aggregateDetailMinZoom {
		return s.fetchAggregateBaseTile(ctx, latest, z, x, y)
	}

	baseRegion := aggregateRegionNameForTile(z, x, y)
	component, ok := latest.Components[baseRegion]
	if !ok || component.ObservedAt.IsZero() {
		return upstream.Result{}, fmt.Errorf("aggregate region %q has no observation", baseRegion)
	}
	region, ok := aggregateRegionNamed(baseRegion)
	if !ok {
		return upstream.Result{}, fmt.Errorf("aggregate region %q is unsupported", baseRegion)
	}
	baseObservedAt := component.ObservedAt
	endpoint := s.config.RadarBaseURL + "/" + region.workspace + "/ows"
	query := pinnedWMSQuery(region.layer, tileBounds(z, x, y), baseObservedAt)
	target := endpoint + "?" + query.Encode()
	key := aggregateRegionalTileKey(baseRegion, baseObservedAt, z, x, y)

	type baseResponse struct {
		result upstream.Result
		err    error
	}
	baseReady := make(chan baseResponse, 1)
	go func() {
		result, err := s.fetcher.Get(ctx, key, target, "image/png", s.config.TileTTL, "image/png")
		baseReady <- baseResponse{result: result, err: err}
	}()

	detailCtx, cancelDetail := context.WithTimeout(ctx, s.aggregateDetailTimeout)
	defer cancelDetail()
	type detailResponse struct {
		detail aggregateStationDetail
		err    error
	}
	detailReady := make(chan detailResponse, 1)
	go func() {
		detail, err := s.fetchAggregateStationDetail(detailCtx, latest, z, x, y)
		detailReady <- detailResponse{detail: detail, err: err}
	}()

	base := <-baseReady
	if base.err != nil {
		return upstream.Result{}, base.err
	}

	// Prefer a detail result that finished while the base tile was loading, even
	// if its short context deadline expired just before the base completed.
	var detail detailResponse
	select {
	case detail = <-detailReady:
	default:
		select {
		case detail = <-detailReady:
		case <-detailCtx.Done():
			return base.result, nil
		}
	}
	if detail.err != nil {
		return base.result, nil
	}

	generation := detail.detail.observedAt.UnixMilli()
	compositeKey := fmt.Sprintf(
		"tile:aggregate-composite:%s:%d:%s:%d:%d:%d:%d",
		baseRegion,
		baseObservedAt.UnixMilli(),
		detail.detail.station.id,
		generation,
		z,
		x,
		y,
	)
	result, err := s.fetcher.Derive(ctx, compositeKey, s.config.TileTTL, "image/png", func(context.Context) (upstream.Result, error) {
		filtered, err := filterStationReflectivityTile("reflectivity", detail.detail.result.Value.Body)
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
		result.State = combinedCacheState(base.result.State, detail.detail.result.State)
		return result, nil
	})
	if err != nil {
		// High-resolution detail is optional. An invalid or temporarily malformed
		// station image must not make the valid regional mosaic unavailable.
		return base.result, nil
	}
	return result, nil
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
	key := fmt.Sprintf("tile:aggregate-national:%s:%d:%d:%d", latest.Version, z, x, y)
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

func (s *Service) fetchAggregateStationDetail(ctx context.Context, latest Latest, z, x, y int) (aggregateStationDetail, error) {
	regionName := aggregateRegionNameForTile(z, x, y)
	component, ok := latest.Components[regionName]
	if !ok || component.ObservedAt.IsZero() {
		return aggregateStationDetail{}, fmt.Errorf("aggregate region %q has no observation", regionName)
	}
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
		return aggregateStationDetail{}, err
	}
	station, err := nearestAggregateDetailStation(catalog.Value.Body, z, x, y)
	if err != nil {
		return aggregateStationDetail{}, err
	}
	if station.region != regionName {
		return aggregateStationDetail{}, fmt.Errorf("station %s is outside aggregate region %q", station.id, regionName)
	}

	selection := Selection{Product: "reflectivity", Station: station.id, Elevation: "0.5"}
	endpoint, layer := s.stationEndpointLayer(selection)
	latestStation, capabilities, err := s.fetchLatestLayer(ctx, endpoint, layer)
	if err != nil {
		return aggregateStationDetail{}, err
	}
	// A replica can have station capabilities cached from before the regional
	// anchor arrived. Refresh once before choosing an exact scan at/before it.
	if latestStation.Before(component.ObservedAt) {
		latestStation, capabilities, err = s.refreshLatestLayer(ctx, endpoint, layer)
		if err != nil {
			return aggregateStationDetail{}, err
		}
	}
	maxLag := aggregateDetailMaxLag
	if s.config.RadarStaleAfter < maxLag {
		maxLag = s.config.RadarStaleAfter
	}
	if latestStation.Before(component.ObservedAt) && component.ObservedAt.Sub(latestStation) > maxLag {
		return aggregateStationDetail{}, fmt.Errorf("station %s latest scan is %s behind aggregate", station.id, component.ObservedAt.Sub(latestStation).Round(time.Second))
	}
	observations, err := layerObservationTimes(capabilities.Value.Body, layer)
	if err != nil {
		return aggregateStationDetail{}, err
	}
	observedAt, ok := observationAtOrBefore(observations, component.ObservedAt)
	if !ok {
		return aggregateStationDetail{}, errors.New("station has no scan at or before the regional observation")
	}
	if component.ObservedAt.Sub(observedAt) > maxLag {
		return aggregateStationDetail{}, fmt.Errorf("station %s matching scan is %s behind aggregate", station.id, component.ObservedAt.Sub(observedAt).Round(time.Second))
	}

	query := pinnedWMSQuery(layer, tileBounds(z, x, y), observedAt)
	target := endpoint + "?" + query.Encode()
	key := fmt.Sprintf(
		"tile:aggregate-station:%s:%d:%d:%d:%d",
		station.id,
		observedAt.UnixMilli(),
		z,
		x,
		y,
	)
	result, err := s.fetcher.Get(ctx, key, target, "image/png", s.config.TileTTL, "image/png")
	if err != nil {
		return aggregateStationDetail{}, err
	}
	return aggregateStationDetail{station: station, observedAt: observedAt, result: result}, nil
}

func observationAtOrBefore(observations []time.Time, anchor time.Time) (time.Time, bool) {
	for index := len(observations) - 1; index >= 0; index-- {
		if !observations[index].After(anchor) {
			return observations[index], true
		}
	}
	return time.Time{}, false
}

func nearestAggregateDetailStation(body []byte, z, x, y int) (aggregateDetailStation, error) {
	var catalog radarStationCatalog
	if err := json.Unmarshal(body, &catalog); err != nil {
		return aggregateDetailStation{}, fmt.Errorf("decode radar stations: %w", err)
	}

	selectionZ, selectionX, selectionY := aggregateDetailSelectionTile(z, x, y)
	selectionBounds := geographicTileBounds(selectionZ, selectionX, selectionY)
	centerLatitude := (selectionBounds.minY + selectionBounds.maxY) / 2
	centerLongitude := (selectionBounds.minX + selectionBounds.maxX) / 2
	longitudeScale := math.Cos(centerLatitude * math.Pi / 180)
	var nearest aggregateDetailStation
	found := false
	seen := make(map[string]bool)
	for _, feature := range catalog.Features {
		id := strings.ToUpper(strings.TrimSpace(feature.Properties.ID))
		if seen[id] || !supportedAggregateDetailStation(id) || feature.Geometry.Type != "Point" || len(feature.Geometry.Coordinates) < 2 {
			continue
		}
		longitude := feature.Geometry.Coordinates[0]
		latitude := feature.Geometry.Coordinates[1]
		if math.IsNaN(latitude) || math.IsInf(latitude, 0) || math.IsNaN(longitude) || math.IsInf(longitude, 0) || latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180 {
			continue
		}
		seen[id] = true
		// Require the radar footprint to cover the whole selection tile. This
		// makes station choice stable for all descendant tiles, rather than
		// switching sources at an arbitrary child-tile edge.
		if longitude-stationCoverageRadiusDegrees > selectionBounds.minX ||
			longitude+stationCoverageRadiusDegrees < selectionBounds.maxX ||
			latitude-stationCoverageRadiusDegrees > selectionBounds.minY ||
			latitude+stationCoverageRadiusDegrees < selectionBounds.maxY {
			continue
		}
		dx := (longitude - centerLongitude) * longitudeScale
		dy := latitude - centerLatitude
		distance := dx*dx + dy*dy
		candidate := aggregateDetailStation{
			id:       id,
			region:   aggregateRegionForLocation(latitude, longitude),
			distance: distance,
		}
		if !found || candidate.distance < nearest.distance || (candidate.distance == nearest.distance && candidate.id < nearest.id) {
			nearest = candidate
			found = true
		}
	}
	if !found {
		return aggregateDetailStation{}, errors.New("no station coverage intersects tile")
	}
	return nearest, nil
}

func aggregateDetailSelectionTile(z, x, y int) (int, int, int) {
	if z <= aggregateDetailSelectionZoom {
		return z, x, y
	}
	shift := z - aggregateDetailSelectionZoom
	return aggregateDetailSelectionZoom, x >> shift, y >> shift
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
