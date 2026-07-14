package radar

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
)

const (
	aggregateSnapshotSchema          = byte(1)
	aggregateSnapshotSignatureBytes  = 16
	aggregateSnapshotPayloadBytes    = 1 + 8 + 8 + 8*5
	aggregateSnapshotMaxLength       = 128
	aggregateSnapshotFutureClockSkew = 2 * time.Minute
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

	payload := make([]byte, aggregateSnapshotPayloadBytes)
	payload[0] = aggregateSnapshotSchema
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
	if aggregateVersion(observations, missing) != latest.Version {
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
	if err != nil || len(payload) != aggregateSnapshotPayloadBytes || base64.RawURLEncoding.EncodeToString(payload) != parts[0] {
		return decodedAggregateSnapshot{}, errors.New("aggregate snapshot payload is invalid")
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || len(signature) != aggregateSnapshotSignatureBytes || base64.RawURLEncoding.EncodeToString(signature) != parts[1] {
		return decodedAggregateSnapshot{}, errors.New("aggregate snapshot signature is invalid")
	}
	if !hmac.Equal(signature, signAggregateSnapshot(payload, generation, key)) {
		return decodedAggregateSnapshot{}, errors.New("aggregate snapshot signature does not match")
	}
	if payload[0] != aggregateSnapshotSchema {
		return decodedAggregateSnapshot{}, errors.New("aggregate snapshot schema is unsupported")
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
	if aggregateVersion(observations, missing) != generation {
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
	}
	return decodedAggregateSnapshot{latest: latest, expired: now.After(expiresAt)}, nil
}

func signAggregateSnapshot(payload []byte, generation, key string) []byte {
	mac := hmac.New(sha256.New, []byte(key))
	_, _ = mac.Write([]byte("radar.aggregate.v1\x00"))
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
	return true
}
