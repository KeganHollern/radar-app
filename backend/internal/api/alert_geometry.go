package api

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/url"
	"path"
	"sort"
	"strings"
	"sync"
	"time"
)

type zoneRequest struct {
	key      string
	target   string
	priority int
}

type zoneResult struct {
	key      string
	polygons multiPolygon
	err      error
}

type position []float64
type linearRing []position
type polygon []linearRing
type multiPolygon []polygon

func (s *Server) enrichAlerts(ctx context.Context, body []byte) ([]byte, error) {
	decorated, err := decorateAlerts(body)
	if err != nil {
		return nil, err
	}
	var collection featureCollection
	if err := json.Unmarshal(decorated, &collection); err != nil {
		return nil, fmt.Errorf("decode decorated alerts: %w", err)
	}
	base, err := url.Parse(s.config.NWSBaseURL)
	if err != nil || base.Scheme == "" || base.Host == "" {
		// Provider configuration errors should not suppress otherwise valid CAP
		// alerts. They simply disable the optional zone fallback.
		return decorated, nil
	}

	requests := make(map[string]zoneRequest)
	for _, feature := range collection.Features {
		if feature["geometry"] != nil {
			continue
		}
		properties, ok := feature["properties"].(map[string]any)
		if !ok {
			continue
		}
		priority := alertPriority(properties)
		for _, raw := range affectedZoneURLs(properties) {
			request, ok := trustedZoneRequest(raw, base)
			if !ok {
				continue
			}
			if existing, found := requests[request.key]; !found || priority > existing.priority {
				request.priority = priority
				requests[request.key] = request
			}
		}
	}
	queue := make([]zoneRequest, 0, len(requests))
	for _, request := range requests {
		queue = append(queue, request)
	}
	sort.Slice(queue, func(i, j int) bool {
		if queue[i].priority == queue[j].priority {
			return queue[i].key < queue[j].key
		}
		return queue[i].priority > queue[j].priority
	})

	// Fresh cache hits do not consume the per-enrichment request budget. This
	// lets a large alert set make forward progress over successive refreshes.
	resolved := make(map[string]multiPolygon, len(queue))
	misses := make([]zoneRequest, 0, len(queue))
	now := time.Now().UTC()
	for _, request := range queue {
		if polygons, ok := s.cachedZone(request); ok {
			resolved[request.key] = polygons
			continue
		}
		if s.zoneFailureCoolingDown(request.key, now) {
			continue
		}
		misses = append(misses, request)
	}
	if len(misses) > s.config.AlertZoneMax {
		misses = misses[:s.config.AlertZoneMax]
	}

	failures := 0
	if len(misses) > 0 {
		resolveCtx, cancel := context.WithTimeout(ctx, s.config.AlertZoneTimeout)
		defer cancel()
		jobs := make(chan zoneRequest, len(misses))
		results := make(chan zoneResult, len(misses))
		for _, request := range misses {
			jobs <- request
		}
		close(jobs)

		workers := s.config.AlertZoneWorkers
		if workers > len(misses) {
			workers = len(misses)
		}
		var wait sync.WaitGroup
		wait.Add(workers)
		for range workers {
			go func() {
				defer wait.Done()
				for request := range jobs {
					polygons, err := s.fetchZone(resolveCtx, request)
					results <- zoneResult{key: request.key, polygons: polygons, err: err}
				}
			}()
		}
		wait.Wait()
		close(results)

		for result := range results {
			if result.err != nil || len(result.polygons) == 0 {
				failures++
				s.recordZoneFailure(result.key, time.Now().UTC())
				continue
			}
			s.clearZoneFailure(result.key)
			resolved[result.key] = result.polygons
		}
	}
	if failures > 0 && s.logger != nil {
		s.logger.Debug("some alert zones could not be resolved", "failed", failures, "fetched", len(misses), "requested", len(queue))
	}

	for _, feature := range collection.Features {
		if feature["geometry"] != nil {
			continue
		}
		properties, ok := feature["properties"].(map[string]any)
		if !ok {
			continue
		}
		var combined multiPolygon
		resolvedCount := 0
		seenZones := make(map[string]bool)
		for _, raw := range affectedZoneURLs(properties) {
			request, ok := trustedZoneRequest(raw, base)
			if !ok || seenZones[request.key] {
				continue
			}
			seenZones[request.key] = true
			polygons, ok := resolved[request.key]
			if !ok {
				continue
			}
			combined = append(combined, polygons...)
			resolvedCount++
		}
		requestedCount := len(seenZones)
		properties["radarGeometryZonesRequested"] = requestedCount
		properties["radarGeometryZonesResolved"] = resolvedCount
		properties["radarGeometryZoneCount"] = resolvedCount
		properties["radarGeometryPartial"] = resolvedCount < requestedCount
		if len(combined) == 0 {
			continue
		}
		feature["geometry"] = map[string]any{"type": "MultiPolygon", "coordinates": combined}
		properties["radarGeometrySource"] = "affectedZones"
		properties["radarGeometrySimplified"] = true
		properties["radarGeometrySimplifyToleranceDegrees"] = zoneSimplifyToleranceDegrees
	}
	return json.Marshal(collection)
}

func (s *Server) cachedZone(request zoneRequest) (multiPolygon, bool) {
	result, ok := s.fetcher.Cached("alert-zone:" + request.key)
	if !ok {
		return nil, false
	}
	polygons, err := parseZone(request.key, result.Value.Body)
	return polygons, err == nil && len(polygons) > 0
}

func (s *Server) fetchZone(ctx context.Context, request zoneRequest) (multiPolygon, error) {
	result, err := s.fetcher.Get(
		ctx,
		"alert-zone:"+request.key,
		request.target,
		"application/geo+json,application/json",
		s.config.AlertZoneTTL,
		"application/geo+json",
		"application/json",
	)
	if err != nil {
		return nil, err
	}
	return parseZone(request.key, result.Value.Body)
}

func parseZone(key string, body []byte) (multiPolygon, error) {
	var feature struct {
		Type     string `json:"type"`
		Geometry *struct {
			Type        string          `json:"type"`
			Coordinates json.RawMessage `json:"coordinates"`
		} `json:"geometry"`
	}
	if err := json.Unmarshal(body, &feature); err != nil {
		return nil, fmt.Errorf("decode NWS zone %s: %w", key, err)
	}
	if feature.Type != "Feature" || feature.Geometry == nil {
		return nil, fmt.Errorf("NWS zone %s is not a GeoJSON feature with geometry", key)
	}

	switch feature.Geometry.Type {
	case "Polygon":
		var coordinates polygon
		if err := json.Unmarshal(feature.Geometry.Coordinates, &coordinates); err != nil || !validPolygon(coordinates) {
			return nil, fmt.Errorf("NWS zone %s has invalid Polygon coordinates", key)
		}
		coordinates = simplifyPolygon(coordinates, zoneSimplifyToleranceDegrees)
		return multiPolygon{coordinates}, nil
	case "MultiPolygon":
		var coordinates multiPolygon
		if err := json.Unmarshal(feature.Geometry.Coordinates, &coordinates); err != nil || !validMultiPolygon(coordinates) {
			return nil, fmt.Errorf("NWS zone %s has invalid MultiPolygon coordinates", key)
		}
		return simplifyMultiPolygon(coordinates, zoneSimplifyToleranceDegrees), nil
	default:
		return nil, fmt.Errorf("NWS zone %s has unsupported geometry %q", key, feature.Geometry.Type)
	}
}

func (s *Server) zoneFailureCoolingDown(key string, now time.Time) bool {
	s.zoneFailureMu.Lock()
	defer s.zoneFailureMu.Unlock()
	expires, ok := s.zoneFailures[key]
	if !ok {
		return false
	}
	if now.Before(expires) {
		return true
	}
	delete(s.zoneFailures, key)
	return false
}

func (s *Server) recordZoneFailure(key string, now time.Time) {
	s.zoneFailureMu.Lock()
	defer s.zoneFailureMu.Unlock()
	if s.zoneFailures == nil {
		s.zoneFailures = make(map[string]time.Time)
	}
	s.zoneFailures[key] = now.Add(s.config.AlertZoneFailTTL)
}

func (s *Server) clearZoneFailure(key string) {
	s.zoneFailureMu.Lock()
	defer s.zoneFailureMu.Unlock()
	delete(s.zoneFailures, key)
}

func trustedZoneRequest(raw string, base *url.URL) (zoneRequest, bool) {
	reference, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || reference.User != nil || reference.RawQuery != "" || reference.Fragment != "" {
		return zoneRequest{}, false
	}
	if !strings.EqualFold(reference.Scheme, base.Scheme) || !strings.EqualFold(reference.Host, base.Host) {
		return zoneRequest{}, false
	}
	if path.Clean(reference.Path) != reference.Path {
		return zoneRequest{}, false
	}
	basePath := strings.TrimRight(base.Path, "/")
	prefix := basePath + "/zones/"
	if !strings.HasPrefix(reference.Path, prefix) {
		return zoneRequest{}, false
	}
	parts := strings.Split(strings.TrimPrefix(reference.Path, prefix), "/")
	if len(parts) != 2 || !allowedZoneType(parts[0]) || !validZoneID(parts[1]) {
		return zoneRequest{}, false
	}

	target := *base
	target.Path = prefix + parts[0] + "/" + parts[1]
	target.RawPath = ""
	target.RawQuery = ""
	target.Fragment = ""
	return zoneRequest{key: parts[0] + ":" + parts[1], target: target.String()}, true
}

func allowedZoneType(value string) bool {
	switch value {
	case "land", "marine", "forecast", "public", "coastal", "offshore", "fire", "county":
		return true
	default:
		return false
	}
}

func validZoneID(value string) bool {
	if len(value) < 3 || len(value) > 12 || value != strings.ToUpper(value) {
		return false
	}
	for _, r := range value {
		if (r < 'A' || r > 'Z') && (r < '0' || r > '9') && r != '-' {
			return false
		}
	}
	return true
}

func affectedZoneURLs(properties map[string]any) []string {
	raw, ok := properties["affectedZones"]
	if !ok {
		return nil
	}
	switch values := raw.(type) {
	case []any:
		result := make([]string, 0, len(values))
		for _, value := range values {
			if text, ok := value.(string); ok {
				result = append(result, text)
			}
		}
		return result
	case []string:
		return values
	default:
		return nil
	}
}

func alertPriority(properties map[string]any) int {
	severity, _ := properties["severity"].(string)
	urgency, _ := properties["urgency"].(string)
	priorities := map[string]int{"Extreme": 400, "Severe": 300, "Moderate": 200, "Minor": 100}
	priority := priorities[severity]
	if urgency == "Immediate" {
		priority += 50
	}
	return priority
}

func validMultiPolygon(value multiPolygon) bool {
	if len(value) == 0 {
		return false
	}
	for _, item := range value {
		if !validPolygon(item) {
			return false
		}
	}
	return true
}

func validPolygon(value polygon) bool {
	if len(value) == 0 {
		return false
	}
	for _, ring := range value {
		if !validRing(ring) {
			return false
		}
	}
	return true
}

func validRing(ring linearRing) bool {
	if len(ring) < 4 || !positionsEqual(ring[0], ring[len(ring)-1]) {
		return false
	}
	unique := make(map[[2]float64]struct{}, len(ring)-1)
	for _, point := range ring {
		if len(point) < 2 || math.IsNaN(point[0]) || math.IsNaN(point[1]) || math.IsInf(point[0], 0) || math.IsInf(point[1], 0) || point[0] < -180 || point[0] > 180 || point[1] < -90 || point[1] > 90 {
			return false
		}
		unique[[2]float64{point[0], point[1]}] = struct{}{}
	}
	return len(unique) >= 3
}
