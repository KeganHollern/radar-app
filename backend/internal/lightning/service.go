package lightning

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"math"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	SourceName      = "NOAA GOES-R Geostationary Lightning Mapper"
	AttributionText = "NOAA/NESDIS GOES-R Geostationary Lightning Mapper (GLM)"
	FlashKind       = "satellite-detected lightning flash"
	EastSourceID    = "G19"
	WestSourceID    = "G18"
)

type Flash struct {
	ID         string
	Latitude   float64
	Longitude  float64
	ObservedAt time.Time
	ReceivedAt time.Time
	Satellite  string
}

type Batch struct {
	Source    string
	ObjectKey string
	ObjectEnd time.Time
	Flashes   []Flash
}

type Bounds struct {
	West  float64
	South float64
	East  float64
	North float64
}

func ParseBounds(raw string) (*Bounds, error) {
	parts := strings.Split(raw, ",")
	if len(parts) != 4 {
		return nil, errors.New("bbox must contain west,south,east,north")
	}
	values := make([]float64, 4)
	for index, part := range parts {
		value, err := strconv.ParseFloat(strings.TrimSpace(part), 64)
		if err != nil || math.IsNaN(value) || math.IsInf(value, 0) {
			return nil, errors.New("bbox coordinates must be finite numbers")
		}
		values[index] = value
	}
	bounds := &Bounds{West: values[0], South: values[1], East: values[2], North: values[3]}
	if bounds.West < -180 || bounds.West > 180 || bounds.East < -180 || bounds.East > 180 {
		return nil, errors.New("bbox longitude must be between -180 and 180")
	}
	if bounds.South < -90 || bounds.South > 90 || bounds.North < -90 || bounds.North > 90 {
		return nil, errors.New("bbox latitude must be between -90 and 90")
	}
	if bounds.South >= bounds.North {
		return nil, errors.New("bbox south must be less than north")
	}
	if bounds.West == bounds.East {
		return nil, errors.New("bbox west and east must differ")
	}
	longitudeSpan := bounds.East - bounds.West
	if longitudeSpan < 0 {
		longitudeSpan += 360
	}
	if longitudeSpan > 160 || bounds.North-bounds.South > 80 {
		return nil, errors.New("bbox may span at most 160 degrees longitude and 80 degrees latitude")
	}
	return bounds, nil
}

func (b Bounds) Contains(latitude, longitude float64) bool {
	if latitude < b.South || latitude > b.North {
		return false
	}
	if b.West < b.East {
		return longitude >= b.West && longitude <= b.East
	}
	// west > east intentionally represents a box crossing the antimeridian.
	return longitude >= b.West || longitude <= b.East
}

type FeatureCollection struct {
	Type     string    `json:"type"`
	Features []Feature `json:"features"`
}

type Feature struct {
	Type       string            `json:"type"`
	ID         string            `json:"id"`
	Geometry   PointGeometry     `json:"geometry"`
	Properties FeatureProperties `json:"properties"`
}

type PointGeometry struct {
	Type        string     `json:"type"`
	Coordinates [2]float64 `json:"coordinates"`
}

type FeatureProperties struct {
	ID         string    `json:"id"`
	Kind       string    `json:"kind"`
	ObservedAt time.Time `json:"observedAt"`
	ReceivedAt time.Time `json:"receivedAt"`
	Satellite  string    `json:"satellite"`
}

type Envelope struct {
	SchemaVersion string            `json:"schemaVersion"`
	Mode          string            `json:"mode"`
	Generation    string            `json:"generation"`
	ObservedAt    *time.Time        `json:"observedAt,omitempty"`
	CheckedAt     *time.Time        `json:"checkedAt,omitempty"`
	Stale         bool              `json:"stale"`
	Available     bool              `json:"available"`
	Source        string            `json:"source"`
	Attribution   string            `json:"attribution"`
	RetentionMS   int64             `json:"retentionMs"`
	Data          FeatureCollection `json:"data"`
}

type ServiceOptions struct {
	Retention     time.Duration
	StaleAfter    time.Duration
	MaxFlashes    int
	SeamLongitude float64
}

type objectState struct {
	end time.Time
}

type sourceState struct {
	checkedAt  time.Time
	productEnd time.Time
}

type Service struct {
	mu             sync.RWMutex
	retention      time.Duration
	staleAfter     time.Duration
	maxFlashes     int
	seamLongitude  float64
	flashes        map[string]Flash
	objects        map[string]objectState
	sources        map[string]sourceState
	generation     string
	subscribers    map[uint64]chan struct{}
	nextSubscriber uint64
}

func NewService(options ServiceOptions) *Service {
	if options.Retention <= 0 {
		options.Retention = 90 * time.Second
	} else if options.Retention > maxLiveRetention {
		options.Retention = maxLiveRetention
	}
	if options.StaleAfter <= 0 {
		options.StaleAfter = options.Retention
	}
	if options.MaxFlashes <= 0 {
		options.MaxFlashes = 20000
	} else if options.MaxFlashes > maxLiveFlashes {
		options.MaxFlashes = maxLiveFlashes
	}
	if math.IsNaN(options.SeamLongitude) || math.IsInf(options.SeamLongitude, 0) || options.SeamLongitude < -130 || options.SeamLongitude > -80 {
		options.SeamLongitude = -105
	}
	service := &Service{
		retention:     options.Retention,
		staleAfter:    options.StaleAfter,
		maxFlashes:    options.MaxFlashes,
		seamLongitude: options.SeamLongitude,
		flashes:       make(map[string]Flash),
		objects:       make(map[string]objectState),
		sources:       make(map[string]sourceState),
		subscribers:   make(map[uint64]chan struct{}),
	}
	service.generation = generationFor(nil, nil)
	return service
}

func (s *Service) Ingest(batch Batch, now time.Time) bool {
	now = now.UTC()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked(now)
	batch.ObjectEnd = batch.ObjectEnd.UTC()
	if !validSource(batch.Source) || batch.ObjectKey == "" || batch.ObjectEnd.IsZero() || !batch.ObjectEnd.After(now.Add(-s.retention)) || batch.ObjectEnd.After(now.Add(30*time.Second)) {
		return false
	}
	if _, exists := s.objects[batch.ObjectKey]; exists {
		return false
	}
	s.objects[batch.ObjectKey] = objectState{end: batch.ObjectEnd.UTC()}
	state := s.sources[batch.Source]
	if batch.ObjectEnd.After(state.productEnd) {
		state.productEnd = batch.ObjectEnd
		s.sources[batch.Source] = state
	}
	for _, flash := range batch.Flashes {
		if flash.ID == "" || math.IsNaN(flash.Latitude) || math.IsInf(flash.Latitude, 0) || math.IsNaN(flash.Longitude) || math.IsInf(flash.Longitude, 0) || flash.Latitude < -90 || flash.Latitude > 90 || flash.Longitude < -180 || flash.Longitude > 180 {
			continue
		}
		flash.ObservedAt = flash.ObservedAt.UTC()
		flash.ReceivedAt = flash.ReceivedAt.UTC()
		if flash.ReceivedAt.IsZero() {
			flash.ReceivedAt = now
		}
		if flash.ObservedAt.IsZero() || !flash.ObservedAt.After(now.Add(-s.retention)) || flash.ObservedAt.After(now.Add(30*time.Second)) {
			continue
		}
		if _, exists := s.flashes[flash.ID]; !exists {
			s.flashes[flash.ID] = flash
		}
	}
	s.limitLocked()
	s.updateGenerationLocked()
	s.notifyLocked()
	return true
}

func (s *Service) MarkChecked(source string, now time.Time) {
	if !validSource(source) {
		return
	}
	now = now.UTC()
	s.mu.Lock()
	defer s.mu.Unlock()
	state := s.sources[source]
	state.checkedAt = now
	s.sources[source] = state
	s.pruneLocked(now)
}

func (s *Service) Snapshot(bounds *Bounds, now time.Time) Envelope {
	now = now.UTC()
	s.mu.Lock()
	s.pruneLocked(now)
	flashes := make([]Flash, 0, len(s.flashes))
	for _, flash := range s.flashes {
		flashes = append(flashes, flash)
	}
	generation := s.generation
	observedAt, checkedAt, available, stale := s.healthLocked(bounds, now)
	retentionMS := s.retention.Milliseconds()
	s.mu.Unlock()

	filtered := flashes[:0]
	for _, flash := range flashes {
		if bounds == nil || bounds.Contains(flash.Latitude, flash.Longitude) {
			filtered = append(filtered, flash)
		}
	}
	flashes = filtered
	sort.Slice(flashes, func(i, j int) bool {
		if flashes[i].ObservedAt.Equal(flashes[j].ObservedAt) {
			return flashes[i].ID < flashes[j].ID
		}
		return flashes[i].ObservedAt.Before(flashes[j].ObservedAt)
	})
	features := make([]Feature, 0, len(flashes))
	for _, flash := range flashes {
		features = append(features, Feature{
			Type: "Feature",
			ID:   flash.ID,
			Geometry: PointGeometry{
				Type:        "Point",
				Coordinates: [2]float64{flash.Longitude, flash.Latitude},
			},
			Properties: FeatureProperties{
				ID:         flash.ID,
				Kind:       FlashKind,
				ObservedAt: flash.ObservedAt,
				ReceivedAt: flash.ReceivedAt,
				Satellite:  flash.Satellite,
			},
		})
	}
	return Envelope{
		SchemaVersion: "1",
		Mode:          "event",
		Generation:    generation,
		ObservedAt:    observedAt,
		CheckedAt:     checkedAt,
		Stale:         stale,
		Available:     available,
		Source:        SourceName,
		Attribution:   AttributionText,
		RetentionMS:   retentionMS,
		Data:          FeatureCollection{Type: "FeatureCollection", Features: features},
	}
}

func (s *Service) Subscribe() (<-chan struct{}, func()) {
	s.mu.Lock()
	id := s.nextSubscriber
	s.nextSubscriber++
	updates := make(chan struct{}, 1)
	s.subscribers[id] = updates
	s.mu.Unlock()
	var once sync.Once
	return updates, func() {
		once.Do(func() {
			s.mu.Lock()
			delete(s.subscribers, id)
			s.mu.Unlock()
		})
	}
}

func (s *Service) pruneLocked(now time.Time) {
	cutoff := now.Add(-s.retention)
	changed := false
	for id, flash := range s.flashes {
		if !flash.ObservedAt.After(cutoff) {
			delete(s.flashes, id)
			changed = true
		}
	}
	for key, object := range s.objects {
		if !object.end.After(cutoff) {
			delete(s.objects, key)
			changed = true
		}
	}
	if changed {
		s.updateGenerationLocked()
	}
}

func (s *Service) limitLocked() {
	if len(s.flashes) <= s.maxFlashes {
		return
	}
	ordered := make([]Flash, 0, len(s.flashes))
	for _, flash := range s.flashes {
		ordered = append(ordered, flash)
	}
	sort.Slice(ordered, func(i, j int) bool {
		if ordered[i].ObservedAt.Equal(ordered[j].ObservedAt) {
			return ordered[i].ID < ordered[j].ID
		}
		return ordered[i].ObservedAt.Before(ordered[j].ObservedAt)
	})
	for _, flash := range ordered[:len(ordered)-s.maxFlashes] {
		delete(s.flashes, flash.ID)
	}
}

func (s *Service) updateGenerationLocked() {
	flashIDs := make([]string, 0, len(s.flashes))
	for id := range s.flashes {
		flashIDs = append(flashIDs, id)
	}
	objectKeys := make([]string, 0, len(s.objects))
	for key := range s.objects {
		objectKeys = append(objectKeys, key)
	}
	s.generation = generationFor(flashIDs, objectKeys)
}

func generationFor(flashIDs, objectKeys []string) string {
	sort.Strings(flashIDs)
	sort.Strings(objectKeys)
	hash := sha256.New()
	for _, value := range objectKeys {
		_, _ = hash.Write([]byte("object\x00" + value + "\x00"))
	}
	for _, value := range flashIDs {
		_, _ = hash.Write([]byte("flash\x00" + value + "\x00"))
	}
	return hex.EncodeToString(hash.Sum(nil)[:12])
}

func (s *Service) notifyLocked() {
	for _, updates := range s.subscribers {
		select {
		case updates <- struct{}{}:
		default:
		}
	}
}

func optionalTime(value time.Time) *time.Time {
	if value.IsZero() {
		return nil
	}
	value = value.UTC()
	return &value
}

func (s *Service) healthLocked(bounds *Bounds, now time.Time) (*time.Time, *time.Time, bool, bool) {
	required := s.requiredSources(bounds)
	available := true
	stale := false
	allObserved := true
	allChecked := true
	var oldestObserved time.Time
	var oldestChecked time.Time
	for _, source := range required {
		state := s.sources[source]
		if state.productEnd.IsZero() {
			available = false
			allObserved = false
		} else {
			age := now.Sub(state.productEnd)
			if age > s.staleAfter {
				stale = true
			}
			if age > 2*s.staleAfter {
				available = false
			}
			if oldestObserved.IsZero() || state.productEnd.Before(oldestObserved) {
				oldestObserved = state.productEnd
			}
		}
		if state.checkedAt.IsZero() {
			allChecked = false
		} else if oldestChecked.IsZero() || state.checkedAt.Before(oldestChecked) {
			oldestChecked = state.checkedAt
		}
	}
	if !allObserved {
		oldestObserved = time.Time{}
	}
	if !allChecked {
		oldestChecked = time.Time{}
	}
	return optionalTime(oldestObserved), optionalTime(oldestChecked), available, stale
}

func (s *Service) requiredSources(bounds *Bounds) []string {
	if bounds == nil {
		return []string{EastSourceID, WestSourceID}
	}
	segments := [][2]float64{{bounds.West, bounds.East}}
	if bounds.West > bounds.East {
		segments = [][2]float64{{bounds.West, 180}, {-180, bounds.East}}
	}
	opposite := oppositeSeam(s.seamLongitude)
	needsEast := false
	needsWest := false
	for _, segment := range segments {
		// GOES-19 owns [seam, opposite); GOES-18 owns its complement.
		needsEast = needsEast || (segment[1] >= s.seamLongitude && segment[0] < opposite)
		needsWest = needsWest || segment[0] < s.seamLongitude || segment[1] >= opposite
	}
	sources := make([]string, 0, 2)
	if needsEast {
		sources = append(sources, EastSourceID)
	}
	if needsWest {
		sources = append(sources, WestSourceID)
	}
	return sources
}

func oppositeSeam(seam float64) float64 {
	opposite := seam + 180
	if opposite > 180 {
		opposite -= 360
	}
	return opposite
}

func validSource(source string) bool {
	return source == EastSourceID || source == WestSourceID
}
