package radar

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"
)

const (
	aggregateSnapshotSchemaV1        = byte(1)
	aggregateSnapshotSchemaV2        = byte(2)
	aggregateSnapshotSignatureBytes  = 16
	aggregateSnapshotV1PayloadBytes  = 1 + 8 + 8 + 8*5
	aggregateSnapshotV2PayloadBytes  = aggregateSnapshotV1PayloadBytes + 4 + 8 + 4 + 4
	aggregateSnapshotMaxLength       = 128
	aggregateSnapshotFutureClockSkew = 2 * time.Minute
	aggregateCoordinateScale         = 1_000_000
)

type decodedAggregateSnapshot struct {
	latest  Latest
	expired bool
}

func encodeAggregateSnapshot(latest Latest, key string) (string, error) {
	if len(key) < 32 {
		return "", errors.New("aggregate token key is too short")
	}
	if !validAggregateVersion(latest.Version) {
		return "", errors.New("aggregate version is malformed")
	}

	schema := aggregateSnapshotSchemaV1
	payloadBytes := aggregateSnapshotV1PayloadBytes
	if latest.Detail != nil {
		schema = aggregateSnapshotSchemaV2
		payloadBytes = aggregateSnapshotV2PayloadBytes
	}
	payload := make([]byte, payloadBytes)
	payload[0] = schema
	observations := make(map[string]time.Time, len(aggregateRegions))
	missing := make([]string, 0, len(aggregateRegions))
	var newest time.Time
	for index, region := range aggregateRegions {
		component, ok := latest.Components[region.name]
		if !ok || component.ObservedAt.IsZero() {
			missing = append(missing, region.name)
			continue
		}
		observedAt := component.ObservedAt.UTC()
		if observedAt.UnixNano() <= 0 {
			return "", fmt.Errorf("aggregate region %q has an invalid observation", region.name)
		}
		binary.BigEndian.PutUint64(payload[17+index*8:], uint64(observedAt.UnixNano()))
		observations[region.name] = observedAt
		if newest.IsZero() || observedAt.After(newest) {
			newest = observedAt
		}
	}
	if newest.IsZero() {
		return "", errors.New("aggregate snapshot has no observations")
	}
	sort.Strings(missing)
	expectedVersion := aggregateVersion(observations, missing)
	if latest.Detail != nil {
		if err := encodeAggregateSnapshotDetail(payload, *latest.Detail, latest.Components); err != nil {
			return "", err
		}
		expectedVersion = aggregateVersionWithDetail(observations, missing, *latest.Detail)
	}
	if expectedVersion != latest.Version {
		return "", errors.New("aggregate components do not match version")
	}
	issuedAt := newest.Truncate(time.Second)
	expiresAt := issuedAt.Add(tileGenerationGrace)
	binary.BigEndian.PutUint64(payload[1:9], uint64(issuedAt.Unix()))
	binary.BigEndian.PutUint64(payload[9:17], uint64(expiresAt.Unix()))

	signature := signAggregateSnapshot(payload, latest.Version, key)
	return base64.RawURLEncoding.EncodeToString(payload) + "." + base64.RawURLEncoding.EncodeToString(signature), nil
}

func decodeAggregateSnapshot(token, generation, key string, now time.Time) (decodedAggregateSnapshot, error) {
	if len(key) < 32 {
		return decodedAggregateSnapshot{}, errors.New("aggregate token key is too short")
	}
	if !validAggregateVersion(generation) {
		return decodedAggregateSnapshot{}, errors.New("aggregate version is malformed")
	}
	if token == "" || len(token) > aggregateSnapshotMaxLength {
		return decodedAggregateSnapshot{}, errors.New("aggregate snapshot length is invalid")
	}
	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		return decodedAggregateSnapshot{}, errors.New("aggregate snapshot format is invalid")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil || base64.RawURLEncoding.EncodeToString(payload) != parts[0] {
		return decodedAggregateSnapshot{}, errors.New("aggregate snapshot payload is invalid")
	}
	if len(payload) == 0 {
		return decodedAggregateSnapshot{}, errors.New("aggregate snapshot payload is invalid")
	}
	schema := payload[0]
	if (schema == aggregateSnapshotSchemaV1 && len(payload) != aggregateSnapshotV1PayloadBytes) ||
		(schema == aggregateSnapshotSchemaV2 && len(payload) != aggregateSnapshotV2PayloadBytes) {
		return decodedAggregateSnapshot{}, errors.New("aggregate snapshot payload is invalid")
	}
	if schema != aggregateSnapshotSchemaV1 && schema != aggregateSnapshotSchemaV2 {
		return decodedAggregateSnapshot{}, errors.New("aggregate snapshot schema is unsupported")
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || len(signature) != aggregateSnapshotSignatureBytes || base64.RawURLEncoding.EncodeToString(signature) != parts[1] {
		return decodedAggregateSnapshot{}, errors.New("aggregate snapshot signature is invalid")
	}
	if !hmac.Equal(signature, signAggregateSnapshot(payload, generation, key)) {
		return decodedAggregateSnapshot{}, errors.New("aggregate snapshot signature does not match")
	}
	issuedUnix := int64(binary.BigEndian.Uint64(payload[1:9]))
	expiresUnix := int64(binary.BigEndian.Uint64(payload[9:17]))
	if issuedUnix <= 0 || expiresUnix <= issuedUnix {
		return decodedAggregateSnapshot{}, errors.New("aggregate snapshot validity window is invalid")
	}
	issuedAt := time.Unix(issuedUnix, 0).UTC()
	expiresAt := time.Unix(expiresUnix, 0).UTC()
	if !expiresAt.Equal(issuedAt.Add(tileGenerationGrace)) {
		return decodedAggregateSnapshot{}, errors.New("aggregate snapshot lifetime is invalid")
	}

	components := make(map[string]LatestComponent, len(aggregateRegions))
	observations := make(map[string]time.Time, len(aggregateRegions))
	missing := make([]string, 0, len(aggregateRegions))
	var oldest, newest time.Time
	for index, region := range aggregateRegions {
		nanoseconds := int64(binary.BigEndian.Uint64(payload[17+index*8:]))
		if nanoseconds == 0 {
			missing = append(missing, region.name)
			continue
		}
		if nanoseconds < 0 {
			return decodedAggregateSnapshot{}, fmt.Errorf("aggregate region %q observation is invalid", region.name)
		}
		observedAt := time.Unix(0, nanoseconds).UTC()
		components[region.name] = LatestComponent{ObservedAt: observedAt}
		observations[region.name] = observedAt
		if oldest.IsZero() || observedAt.Before(oldest) {
			oldest = observedAt
		}
		if newest.IsZero() || observedAt.After(newest) {
			newest = observedAt
		}
	}
	if newest.IsZero() || !newest.Truncate(time.Second).Equal(issuedAt) {
		return decodedAggregateSnapshot{}, errors.New("aggregate snapshot issue time is non-canonical")
	}
	sort.Strings(missing)
	var detail *AggregateDetail
	expectedVersion := aggregateVersion(observations, missing)
	if schema == aggregateSnapshotSchemaV2 {
		decodedDetail, err := decodeAggregateSnapshotDetail(payload, components)
		if err != nil {
			return decodedAggregateSnapshot{}, err
		}
		detail = &decodedDetail
		expectedVersion = aggregateVersionWithDetail(observations, missing, decodedDetail)
	}
	if expectedVersion != generation {
		return decodedAggregateSnapshot{}, errors.New("aggregate snapshot does not match version")
	}
	now = now.UTC()
	if issuedAt.After(now.Add(aggregateSnapshotFutureClockSkew)) {
		return decodedAggregateSnapshot{}, errors.New("aggregate snapshot is from the future")
	}

	latest := Latest{
		Product:        "aggregate",
		Station:        "conus",
		Elevation:      "0.5",
		ObservedAt:     oldest,
		Version:        generation,
		Components:     components,
		MissingRegions: missing,
		Detail:         detail,
	}
	if detail != nil {
		latest.Station = detail.Station
	}
	return decodedAggregateSnapshot{latest: latest, expired: now.After(expiresAt)}, nil
}

func encodeAggregateSnapshotDetail(payload []byte, detail AggregateDetail, components map[string]LatestComponent) error {
	if len(payload) != aggregateSnapshotV2PayloadBytes || !validStation(detail.Station) || !supportedAggregateDetailStation(detail.Station) {
		return errors.New("aggregate detail is invalid")
	}
	if detail.ObservedAt.UnixNano() <= 0 {
		return errors.New("aggregate detail observation is invalid")
	}
	latitude, ok := aggregateCoordinateMicrodegrees(detail.Latitude, 90)
	if !ok {
		return errors.New("aggregate detail latitude is invalid")
	}
	longitude, ok := aggregateCoordinateMicrodegrees(detail.Longitude, 180)
	if !ok {
		return errors.New("aggregate detail longitude is invalid")
	}
	region := aggregateRegionForLocation(detail.Latitude, detail.Longitude)
	anchor, ok := components[region]
	if !ok || anchor.ObservedAt.IsZero() || detail.ObservedAt.After(anchor.ObservedAt) || anchor.ObservedAt.Sub(detail.ObservedAt) > aggregateDetailMaxLag {
		return errors.New("aggregate detail observation does not match its regional anchor")
	}
	copy(payload[57:61], detail.Station)
	binary.BigEndian.PutUint64(payload[61:69], uint64(detail.ObservedAt.UTC().UnixNano()))
	binary.BigEndian.PutUint32(payload[69:73], uint32(latitude))
	binary.BigEndian.PutUint32(payload[73:77], uint32(longitude))
	return nil
}

func decodeAggregateSnapshotDetail(payload []byte, components map[string]LatestComponent) (AggregateDetail, error) {
	station := string(payload[57:61])
	if !validStation(station) || !supportedAggregateDetailStation(station) {
		return AggregateDetail{}, errors.New("aggregate snapshot detail station is invalid")
	}
	nanoseconds := int64(binary.BigEndian.Uint64(payload[61:69]))
	if nanoseconds <= 0 {
		return AggregateDetail{}, errors.New("aggregate snapshot detail observation is invalid")
	}
	detail := AggregateDetail{
		Station:    station,
		ObservedAt: time.Unix(0, nanoseconds).UTC(),
		Latitude:   float64(int32(binary.BigEndian.Uint32(payload[69:73]))) / aggregateCoordinateScale,
		Longitude:  float64(int32(binary.BigEndian.Uint32(payload[73:77]))) / aggregateCoordinateScale,
	}
	if !validRadarCoordinate(detail.Latitude, detail.Longitude) {
		return AggregateDetail{}, errors.New("aggregate snapshot detail coordinates are invalid")
	}
	region := aggregateRegionForLocation(detail.Latitude, detail.Longitude)
	anchor, ok := components[region]
	if !ok || anchor.ObservedAt.IsZero() || detail.ObservedAt.After(anchor.ObservedAt) || anchor.ObservedAt.Sub(detail.ObservedAt) > aggregateDetailMaxLag {
		return AggregateDetail{}, errors.New("aggregate snapshot detail does not match its regional anchor")
	}
	return detail, nil
}

func aggregateCoordinateMicrodegrees(value, limit float64) (int32, bool) {
	if math.IsNaN(value) || math.IsInf(value, 0) || value < -limit || value > limit {
		return 0, false
	}
	scaled := math.Round(value * aggregateCoordinateScale)
	canonical := scaled / aggregateCoordinateScale
	if math.Abs(value-canonical) > 1e-9 {
		return 0, false
	}
	return int32(scaled), true
}

func signAggregateSnapshot(payload []byte, generation, key string) []byte {
	mac := hmac.New(sha256.New, []byte(key))
	domain := "radar.aggregate.v1\x00"
	if len(payload) > 0 && payload[0] == aggregateSnapshotSchemaV2 {
		domain = "radar.aggregate.v2\x00"
	}
	_, _ = mac.Write([]byte(domain))
	_, _ = mac.Write([]byte(generation))
	_, _ = mac.Write([]byte{0})
	_, _ = mac.Write(payload)
	return mac.Sum(nil)[:aggregateSnapshotSignatureBytes]
}

func validAggregateVersion(value string) bool {
	if len(value) != 24 || value != strings.ToLower(value) {
		return false
	}
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == 12
}

func sameAggregateComponents(first, second Latest) bool {
	if len(first.Components) != len(second.Components) {
		return false
	}
	for _, region := range aggregateRegions {
		firstComponent, firstOK := first.Components[region.name]
		secondComponent, secondOK := second.Components[region.name]
		if firstOK != secondOK {
			return false
		}
		if firstOK && !firstComponent.ObservedAt.Equal(secondComponent.ObservedAt) {
			return false
		}
	}
	if (first.Detail == nil) != (second.Detail == nil) {
		return false
	}
	if first.Detail == nil {
		return true
	}
	return first.Detail.Station == second.Detail.Station &&
		first.Detail.ObservedAt.Equal(second.Detail.ObservedAt) &&
		first.Detail.Latitude == second.Detail.Latitude &&
		first.Detail.Longitude == second.Detail.Longitude
}
