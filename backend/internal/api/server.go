package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/KeganHollern/radar-app/backend/internal/cache"
	"github.com/KeganHollern/radar-app/backend/internal/config"
	"github.com/KeganHollern/radar-app/backend/internal/radar"
	"github.com/KeganHollern/radar-app/backend/internal/upstream"
)

type Server struct {
	config  config.Config
	logger  *slog.Logger
	fetcher *upstream.Fetcher
	radar   *radar.Service
	handler http.Handler

	zoneFailureMu sync.Mutex
	zoneFailures  map[string]time.Time
}

func New(c config.Config, logger *slog.Logger) *Server {
	transport := &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		DialContext:           (&net.Dialer{Timeout: 5 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          128,
		MaxIdleConnsPerHost:   32,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   5 * time.Second,
		ResponseHeaderTimeout: c.UpstreamTimeout,
	}
	client := &http.Client{Transport: transport, Timeout: c.UpstreamTimeout}
	responseCache := cache.New(c.CacheMaxEntries, c.CacheMaxBytes)
	fetcher := upstream.NewFetcher(client, responseCache, c.UserAgent, c.MaxUpstreamBytes, c.StaleTTL)
	s := &Server{config: c, logger: logger, fetcher: fetcher, zoneFailures: make(map[string]time.Time)}
	s.radar = radar.NewService(c, fetcher)
	s.handler = s.routes()
	return s
}

func (s *Server) Handler() http.Handler {
	return s.handler
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", s.landing)
	mux.HandleFunc("GET /healthz", s.health)
	mux.HandleFunc("GET /readyz", s.ready)
	mux.HandleFunc("GET /api/v1/config", s.clientConfig)
	mux.HandleFunc("GET /api/v1/stations", s.stations)
	mux.HandleFunc("GET /api/v1/alerts", s.alerts)
	mux.HandleFunc("GET /api/v1/radar/latest", s.latest)
	mux.HandleFunc("GET /api/v1/radar/tiles/{product}/{station}/{elevation}/{z}/{x}/{y}", s.tile)
	mux.HandleFunc("GET /api/v1/updates", s.updates)
	return s.recover(s.accessLog(s.headers(mux)))
}

func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok"})
}

func (s *Server) ready(w http.ResponseWriter, _ *http.Request) {
	// Upstream weather providers are intentionally not readiness dependencies: a
	// NOAA outage should degrade live data, not cause a Kubernetes restart loop.
	writeJSON(w, http.StatusOK, map[string]any{"status": "ready"})
}

func (s *Server) clientConfig(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Cache-Control", "public, max-age=300")
	writeJSON(w, http.StatusOK, map[string]any{
		"apiVersion": "v1",
		"liveOnly":   true,
		"refresh": map[string]any{
			"updatesSSE":      s.config.PublicBaseURL + "/api/v1/updates",
			"pollIntervalMs":  s.config.UpdatePoll.Milliseconds(),
			"alertIntervalMs": s.config.AlertTTL.Milliseconds(),
		},
		"radar": map[string]any{
			"latest":       s.config.PublicBaseURL + "/api/v1/radar/latest",
			"tileTemplate": s.config.PublicBaseURL + "/api/v1/radar/tiles/{product}/{station}/{elevation}/{z}/{x}/{y}.png?timestamp={version}",
			"products": []map[string]any{
				{"id": "aggregate", "label": "Aggregated reflectivity", "stationRequired": false, "elevations": []string{"0.5"}},
				{"id": "reflectivity", "label": "Station reflectivity", "stationRequired": true, "elevations": s.radar.Elevations("reflectivity")},
				{"id": "velocity", "label": "Station radial velocity", "stationRequired": true, "elevations": s.radar.Elevations("velocity")},
			},
		},
		"alertColors": alertColors(),
		"attribution": []string{"NOAA", "National Weather Service"},
	})
}

func (s *Server) stations(w http.ResponseWriter, r *http.Request) {
	result, err := s.fetcher.Get(r.Context(), "stations", s.config.StationsURL, "application/geo+json,application/json", s.config.StationTTL, "application/geo+json", "application/json")
	if err != nil {
		writeError(w, http.StatusBadGateway, "upstream_unavailable", err.Error())
		return
	}
	body, err := normalizeStations(result.Value.Body, s.radar.Elevations("reflectivity"), s.radar.Elevations("velocity"))
	if err != nil {
		writeError(w, http.StatusBadGateway, "invalid_upstream_response", err.Error())
		return
	}
	writeCached(w, r, http.StatusOK, body, "application/geo+json", result, "public, max-age=3600, stale-if-error=86400")
}

func (s *Server) alerts(w http.ResponseWriter, r *http.Request) {
	target, err := s.alertsURL(r.URL.Query())
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	raw, err := s.fetcher.Get(r.Context(), "alerts:"+target, target, "application/geo+json", s.config.AlertTTL, "application/geo+json", "application/json")
	if err != nil {
		writeError(w, http.StatusBadGateway, "upstream_unavailable", err.Error())
		return
	}
	result, err := s.enrichedAlerts(r.Context(), target, raw)
	if err != nil {
		writeError(w, http.StatusBadGateway, "invalid_upstream_response", err.Error())
		return
	}
	writeCached(w, r, http.StatusOK, result.Value.Body, "application/geo+json", result, "public, max-age=10, stale-if-error=300")
}

// enrichedAlerts coalesces and briefly caches the expensive national alert
// normalization pass. Each alert scope owns one stable derived-cache slot, and
// the immutable upstream body hash is its source revision. This bounds memory
// while ensuring a changed active-alert collection rebuilds immediately.
// Keeping the derived TTL equal to AlertTTL still lets unchanged collections
// make bounded progress resolving previously uncached zone geometry.
func (s *Server) enrichedAlerts(ctx context.Context, target string, raw upstream.Result) (upstream.Result, error) {
	scopeHash := sha256.Sum256([]byte(target))
	revisionHash := sha256.Sum256(raw.Value.Body)
	key := "alerts-enriched:" + hex.EncodeToString(scopeHash[:])
	revision := hex.EncodeToString(revisionHash[:])
	result, err := s.fetcher.DeriveVersioned(ctx, key, revision, s.config.AlertTTL, "application/geo+json", func(buildCtx context.Context) (upstream.Result, error) {
		body, err := s.enrichAlerts(buildCtx, raw.Value.Body)
		if err != nil {
			return upstream.Result{}, err
		}
		return upstream.Result{Value: cache.Value{
			Body:         body,
			FetchedAt:    raw.Value.FetchedAt,
			CheckedAt:    raw.Value.CheckedAt,
			LastModified: raw.Value.LastModified,
		}, State: raw.State}, nil
	})
	if err != nil {
		return upstream.Result{}, err
	}

	if result.Value.SourceVersion != revision {
		if result.State != cache.Stale {
			return upstream.Result{}, errors.New("derived alerts do not match the requested source revision")
		}
		// A failed new revision may explicitly fall back to the previous
		// normalized collection. It stays stale with its original provenance.
		return result, nil
	}

	// Normalized-body freshness still belongs to the current NWS collection.
	// Refresh that provenance on a 304 without rebuilding identical geometry,
	// but never hide an explicit stale fallback from a failed normalization.
	if result.State != cache.Stale {
		result.State = raw.State
	}
	if !raw.Value.FetchedAt.IsZero() {
		result.Value.FetchedAt = raw.Value.FetchedAt
	}
	if !raw.Value.CheckedAt.IsZero() {
		result.Value.CheckedAt = raw.Value.CheckedAt
	}
	result.Value.LastModified = raw.Value.LastModified
	return result, nil
}

func (s *Server) latest(w http.ResponseWriter, r *http.Request) {
	selection := radar.Selection{
		Product:   r.URL.Query().Get("product"),
		Station:   r.URL.Query().Get("station"),
		Elevation: r.URL.Query().Get("elevation"),
	}
	latest, err := s.radar.Latest(r.Context(), selection)
	if err != nil {
		if isSelectionError(err) {
			writeError(w, http.StatusBadRequest, "invalid_selection", err.Error())
		} else {
			writeError(w, http.StatusBadGateway, "upstream_unavailable", err.Error())
		}
		return
	}
	w.Header().Set("Cache-Control", "public, max-age=5, must-revalidate")
	writeJSON(w, http.StatusOK, latest)
}

func (s *Server) tile(w http.ResponseWriter, r *http.Request) {
	yPart := strings.TrimSuffix(r.PathValue("y"), ".png")
	if yPart == r.PathValue("y") {
		writeError(w, http.StatusNotFound, "not_found", "tile path must end in .png")
		return
	}
	z, errZ := strconv.Atoi(r.PathValue("z"))
	x, errX := strconv.Atoi(r.PathValue("x"))
	y, errY := strconv.Atoi(yPart)
	if errZ != nil || errX != nil || errY != nil {
		writeError(w, http.StatusBadRequest, "invalid_tile", "z, x, and y must be integers")
		return
	}
	selection := radar.Selection{Product: r.PathValue("product"), Station: r.PathValue("station"), Elevation: r.PathValue("elevation")}
	result, err := s.radar.Tile(
		r.Context(),
		selection,
		r.URL.Query().Get("timestamp"),
		r.URL.Query().Get("snapshot"),
		z,
		x,
		y,
	)
	if err != nil {
		if errors.Is(err, radar.ErrInvalidGeneration) {
			writeError(w, http.StatusBadRequest, "invalid_generation", err.Error())
		} else if isSelectionError(err) || strings.Contains(err.Error(), "tile") || strings.Contains(err.Error(), "zoom") {
			writeError(w, http.StatusBadRequest, "invalid_tile", err.Error())
		} else {
			writeError(w, http.StatusBadGateway, "upstream_unavailable", err.Error())
		}
		return
	}
	writeCached(w, r, http.StatusOK, result.Value.Body, "image/png", result, "public, max-age=10, stale-if-error=120")
}

func (s *Server) updates(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming_unavailable", "streaming is unavailable")
		return
	}
	selection := radar.Selection{Product: r.URL.Query().Get("product"), Station: r.URL.Query().Get("station"), Elevation: r.URL.Query().Get("elevation")}
	if _, err := s.radar.Normalize(selection); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_selection", err.Error())
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache, no-transform")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	_, _ = fmt.Fprint(w, "retry: 5000\n\n")
	flusher.Flush()

	var previousVersion string
	send := func() {
		latest, err := s.radar.Latest(r.Context(), selection)
		if err != nil {
			data, _ := json.Marshal(map[string]string{"message": "live radar metadata temporarily unavailable"})
			_, _ = fmt.Fprintf(w, "event: error\ndata: %s\n\n", data)
			flusher.Flush()
			return
		}
		changed := latest.Version != previousVersion
		previousVersion = latest.Version
		data, _ := json.Marshal(map[string]any{"radar": latest, "radarChanged": changed, "refreshAlerts": true})
		_, _ = fmt.Fprintf(w, "event: refresh\nid: %s\ndata: %s\n\n", latest.Version, data)
		flusher.Flush()
	}
	send()
	ticker := time.NewTicker(s.config.UpdatePoll)
	defer ticker.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-ticker.C:
			send()
		}
	}
}

func (s *Server) alertsURL(query url.Values) (string, error) {
	target, err := url.Parse(s.config.NWSBaseURL + "/alerts/active")
	if err != nil {
		return "", err
	}
	upstreamQuery := url.Values{"status": {"actual"}}
	scopes := 0
	if point := strings.TrimSpace(query.Get("point")); point != "" {
		if !validPoint(point) {
			return "", errors.New("point must be latitude,longitude within valid ranges")
		}
		upstreamQuery.Set("point", point)
		scopes++
	}
	if area := strings.ToUpper(strings.TrimSpace(query.Get("area"))); area != "" {
		if len(area) != 2 || !lettersOnly(area) {
			return "", errors.New("area must be a two-letter NWS area code")
		}
		upstreamQuery.Set("area", area)
		scopes++
	}
	if region := strings.ToUpper(strings.TrimSpace(query.Get("region"))); region != "" {
		if len(region) != 2 || !lettersOnly(region) {
			return "", errors.New("region must be a two-letter NWS region code")
		}
		upstreamQuery.Set("region", region)
		scopes++
	}
	if scopes > 1 {
		return "", errors.New("use only one of point, area, or region")
	}
	target.RawQuery = upstreamQuery.Encode()
	return target.String(), nil
}

func validPoint(raw string) bool {
	parts := strings.Split(raw, ",")
	if len(parts) != 2 {
		return false
	}
	lat, errLat := strconv.ParseFloat(strings.TrimSpace(parts[0]), 64)
	lon, errLon := strconv.ParseFloat(strings.TrimSpace(parts[1]), 64)
	return errLat == nil && errLon == nil && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180
}

func lettersOnly(raw string) bool {
	for _, r := range raw {
		if r < 'A' || r > 'Z' {
			return false
		}
	}
	return true
}

func isSelectionError(err error) bool {
	message := err.Error()
	return strings.Contains(message, "product") || strings.Contains(message, "station") || strings.Contains(message, "elevation")
}

type featureCollection struct {
	Type     string           `json:"type"`
	Features []map[string]any `json:"features"`
}

func normalizeStations(body []byte, reflectivityElevations, velocityElevations []string) ([]byte, error) {
	var input featureCollection
	if err := json.Unmarshal(body, &input); err != nil {
		return nil, fmt.Errorf("decode stations: %w", err)
	}
	output := featureCollection{Type: "FeatureCollection", Features: make([]map[string]any, 0, len(input.Features))}
	seen := make(map[string]bool)
	for _, feature := range input.Features {
		properties, _ := feature["properties"].(map[string]any)
		id, _ := properties["rda_id"].(string)
		id = strings.ToUpper(strings.TrimSpace(id))
		if seen[id] || !supportedWSR88D(id) {
			continue
		}
		geometry, ok := feature["geometry"].(map[string]any)
		if !ok {
			continue
		}
		seen[id] = true
		elevations := unionStrings(reflectivityElevations, velocityElevations)
		output.Features = append(output.Features, map[string]any{
			"type":     "Feature",
			"id":       id,
			"geometry": geometry,
			"properties": map[string]any{
				"id":                      id,
				"name":                    properties["name"],
				"latitude":                properties["lat"],
				"longitude":               properties["lon"],
				"wfo":                     properties["wfo_id"],
				"site_elevation_m":        properties["elevmeter"],
				"type":                    "WSR-88D",
				"products":                []string{"reflectivity", "velocity"},
				"elevations":              elevations,
				"reflectivity_elevations": reflectivityElevations,
				"velocity_elevations":     velocityElevations,
				"supports_reflectivity":   len(reflectivityElevations) > 0,
				"supports_velocity":       len(velocityElevations) > 0,
			},
		})
	}
	return json.Marshal(output)
}

func unionStrings(first, second []string) []string {
	seen := make(map[string]bool, len(first)+len(second))
	result := make([]string, 0, len(first)+len(second))
	for _, values := range [][]string{first, second} {
		for _, value := range values {
			if !seen[value] {
				seen[value] = true
				result = append(result, value)
			}
		}
	}
	return result
}

func supportedWSR88D(id string) bool {
	return len(id) == 4 && (id[0] == 'K' || id[0] == 'P' || id == "TJUA")
}

func decorateAlerts(body []byte) ([]byte, error) {
	var collection featureCollection
	if err := json.Unmarshal(body, &collection); err != nil {
		return nil, fmt.Errorf("decode alerts: %w", err)
	}
	if collection.Type != "FeatureCollection" {
		return nil, errors.New("decode alerts: expected a GeoJSON FeatureCollection")
	}
	for _, feature := range collection.Features {
		properties, ok := feature["properties"].(map[string]any)
		if !ok {
			return nil, errors.New("decode alerts: feature properties must be an object")
		}
		event, _ := properties["event"].(string)
		severity, _ := properties["severity"].(string)
		category, color := classifyAlert(event, severity)
		properties["radarCategory"] = category
		properties["radarColor"] = color
	}
	return json.Marshal(collection)
}

func classifyAlert(event, severity string) (string, string) {
	eventLower := strings.ToLower(event)
	switch {
	case strings.Contains(eventLower, "tornado"):
		return "tornado", "#D14D41"
	case strings.Contains(eventLower, "severe thunderstorm"):
		return "severe-thunderstorm", "#DA702C"
	case strings.Contains(eventLower, "flash flood"):
		return "flash-flood", "#3AA99F"
	case strings.Contains(eventLower, "flood"):
		return "flood", "#4385BE"
	case strings.Contains(eventLower, "winter"), strings.Contains(eventLower, "snow"), strings.Contains(eventLower, "ice"), strings.Contains(eventLower, "blizzard"):
		return "winter", "#8B7EC8"
	case strings.Contains(eventLower, "fire"), strings.Contains(eventLower, "red flag"):
		return "fire", "#BC5215"
	}
	colors := alertColors()
	if color, ok := colors[strings.ToLower(severity)]; ok {
		return "other", color
	}
	return "other", colors["unknown"]
}

func alertColors() map[string]string {
	return map[string]string{
		"extreme":  "#D14D41",
		"severe":   "#DA702C",
		"moderate": "#D0A215",
		"minor":    "#4385BE",
		"unknown":  "#8B7EC8",
	}
}

func writeCached(w http.ResponseWriter, r *http.Request, status int, body []byte, contentType string, result upstream.Result, cacheControl string) {
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", cacheControl)
	w.Header().Set("X-Radar-Cache", string(result.State))
	if !result.Value.FetchedAt.IsZero() {
		w.Header().Set("X-Data-Fetched-At", result.Value.FetchedAt.UTC().Format(time.RFC3339Nano))
	}
	if !result.Value.CheckedAt.IsZero() {
		w.Header().Set("X-Data-Checked-At", result.Value.CheckedAt.UTC().Format(time.RFC3339Nano))
	}
	hash := sha256.Sum256(body)
	etag := `"` + hex.EncodeToString(hash[:8]) + `"`
	w.Header().Set("ETag", etag)
	if result.Value.LastModified != "" {
		w.Header().Set("Last-Modified", result.Value.LastModified)
	}
	if matchesIfNoneMatch(r.Header.Get("If-None-Match"), etag) {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

// GET and HEAD use weak comparison for If-None-Match. Cloudflare weakens the
// origin ETag when it compresses a response, so accepting W/"tag" as equivalent
// to "tag" is required to avoid retransferring unchanged alert collections.
func matchesIfNoneMatch(header, current string) bool {
	currentOpaque, ok := opaqueETag(current)
	if !ok {
		return false
	}
	for _, candidate := range strings.Split(header, ",") {
		candidate = strings.TrimSpace(candidate)
		if candidate == "*" {
			return true
		}
		opaque, valid := opaqueETag(candidate)
		if valid && opaque == currentOpaque {
			return true
		}
	}
	return false
}

func opaqueETag(value string) (string, bool) {
	value = strings.TrimSpace(value)
	if strings.HasPrefix(value, "W/") {
		value = strings.TrimSpace(strings.TrimPrefix(value, "W/"))
	}
	if len(value) < 2 || value[0] != '"' || value[len(value)-1] != '"' {
		return "", false
	}
	return value, true
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]any{"error": map[string]string{"code": code, "message": message}})
}

type statusWriter struct {
	http.ResponseWriter
	status      int
	bytes       int64
	wroteHeader bool
}

func (w *statusWriter) WriteHeader(status int) {
	if w.wroteHeader {
		return
	}
	w.wroteHeader = true
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

func (w *statusWriter) Write(body []byte) (int, error) {
	if !w.wroteHeader {
		w.WriteHeader(http.StatusOK)
	}
	written, err := w.ResponseWriter.Write(body)
	w.bytes += int64(written)
	return written, err
}

func (w *statusWriter) Flush() {
	if !w.wroteHeader {
		w.WriteHeader(http.StatusOK)
	}
	if flusher, ok := w.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func (s *Server) accessLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		wrapped := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(wrapped, r)
		attributes := []any{
			"method", r.Method,
			"path", r.URL.Path,
			"status", wrapped.status,
			"duration_ms", time.Since(started).Milliseconds(),
			"response_bytes", wrapped.bytes,
		}
		if state := wrapped.Header().Get("X-Radar-Cache"); state != "" {
			attributes = append(attributes, "cache_state", state)
		}
		if raw := wrapped.Header().Get("X-Data-Checked-At"); raw != "" {
			if checkedAt, err := time.Parse(time.RFC3339Nano, raw); err == nil {
				attributes = append(attributes, "data_checked_age_seconds", max(0, time.Since(checkedAt).Seconds()))
			}
		}
		s.logger.Info("request", attributes...)
	})
}

func (s *Server) headers(next http.Handler) http.Handler {
	allowed := make(map[string]bool, len(s.config.AllowedOrigins))
	for _, origin := range s.config.AllowedOrigins {
		allowed[origin] = true
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		origin := r.Header.Get("Origin")
		if allowed["*"] {
			w.Header().Set("Access-Control-Allow-Origin", "*")
		} else if origin != "" && allowed[origin] {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Add("Vary", "Origin")
		}
		w.Header().Set("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Accept, If-None-Match, Last-Event-ID")
		w.Header().Set("Access-Control-Expose-Headers", "ETag, Last-Modified, X-Data-Fetched-At, X-Data-Checked-At, X-Radar-Cache")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) recover(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if recovered := recover(); recovered != nil {
				s.logger.Error("panic", "error", recovered, "stack", string(debug.Stack()))
				writeError(w, http.StatusInternalServerError, "internal_error", "internal server error")
			}
		}()
		next.ServeHTTP(w, r)
	})
}
