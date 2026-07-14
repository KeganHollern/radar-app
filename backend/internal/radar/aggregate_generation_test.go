package radar

import (
	"encoding/base64"
	"encoding/binary"
	"strings"
	"testing"
	"time"
)

const aggregateSnapshotTestKey = "0123456789abcdef0123456789abcdef"

func TestAggregateSnapshotRoundTripIsStableAndCanonical(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	latest := aggregateSnapshotFixture(now)
	first, err := encodeAggregateSnapshot(latest, aggregateSnapshotTestKey)
	if err != nil {
		t.Fatal(err)
	}
	second, err := encodeAggregateSnapshot(latest, aggregateSnapshotTestKey)
	if err != nil {
		t.Fatal(err)
	}
	if first != second {
		t.Fatal("same aggregate generation produced different snapshot tokens")
	}
	if len(first) > aggregateSnapshotMaxLength || len(first) >= 512 {
		t.Fatalf("snapshot token length = %d", len(first))
	}
	decoded, err := decodeAggregateSnapshot(first, latest.Version, aggregateSnapshotTestKey, now)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.expired || !sameAggregateComponents(decoded.latest, latest) {
		t.Fatalf("unexpected decoded snapshot: %#v", decoded)
	}
}

func TestAggregateSnapshotRejectsTamperingBeforeUse(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	latest := aggregateSnapshotFixture(now)
	token, err := encodeAggregateSnapshot(latest, aggregateSnapshotTestKey)
	if err != nil {
		t.Fatal(err)
	}
	last := token[len(token)-1]
	replacement := byte('A')
	if last == replacement {
		replacement = 'B'
	}
	tampered := token[:len(token)-1] + string(replacement)

	tests := []struct {
		name       string
		token      string
		generation string
		key        string
	}{
		{name: "tampered signature", token: tampered, generation: latest.Version, key: aggregateSnapshotTestKey},
		{name: "wrong key", token: token, generation: latest.Version, key: strings.Repeat("z", 32)},
		{name: "wrong generation", token: token, generation: strings.Repeat("f", 24), key: aggregateSnapshotTestKey},
		{name: "uppercase generation", token: token, generation: strings.ToUpper(latest.Version), key: aggregateSnapshotTestKey},
		{name: "malformed", token: "not-a-token", generation: latest.Version, key: aggregateSnapshotTestKey},
		{name: "oversize", token: strings.Repeat("a", aggregateSnapshotMaxLength+1), generation: latest.Version, key: aggregateSnapshotTestKey},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if _, err := decodeAggregateSnapshot(test.token, test.generation, test.key, now); err == nil {
				t.Fatal("expected invalid snapshot to be rejected")
			}
		})
	}
}

func TestAggregateSnapshotRejectsUnknownSchemaAndRegionReorder(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	latest := aggregateSnapshotFixture(now)
	token, err := encodeAggregateSnapshot(latest, aggregateSnapshotTestKey)
	if err != nil {
		t.Fatal(err)
	}
	payload := aggregateSnapshotPayload(t, token)

	unknownSchema := append([]byte(nil), payload...)
	unknownSchema[0] = aggregateSnapshotSchemaV2 + 1
	if _, err := decodeAggregateSnapshot(
		signedAggregateSnapshot(unknownSchema, latest.Version, aggregateSnapshotTestKey),
		latest.Version,
		aggregateSnapshotTestKey,
		now,
	); err == nil {
		t.Fatal("expected unknown schema to be rejected")
	}

	reordered := append([]byte(nil), payload...)
	first := binary.BigEndian.Uint64(reordered[17:25])
	second := binary.BigEndian.Uint64(reordered[25:33])
	binary.BigEndian.PutUint64(reordered[17:25], second)
	binary.BigEndian.PutUint64(reordered[25:33], first)
	if _, err := decodeAggregateSnapshot(
		signedAggregateSnapshot(reordered, latest.Version, aggregateSnapshotTestKey),
		latest.Version,
		aggregateSnapshotTestKey,
		now,
	); err == nil {
		t.Fatal("expected reordered region observations to be rejected")
	}
}

func TestAggregateSnapshotV2RoundTripPinsDetailAndV1RemainsAccepted(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	legacy := aggregateSnapshotFixture(now)
	legacyToken, err := encodeAggregateSnapshot(legacy, aggregateSnapshotTestKey)
	if err != nil {
		t.Fatal(err)
	}
	if payload := aggregateSnapshotPayload(t, legacyToken); payload[0] != aggregateSnapshotSchemaV1 {
		t.Fatalf("legacy snapshot schema = %d", payload[0])
	}
	if _, err := decodeAggregateSnapshot(legacyToken, legacy.Version, aggregateSnapshotTestKey, now); err != nil {
		t.Fatalf("decode schema 1: %v", err)
	}

	detail := AggregateDetail{
		Station:    "KGRK",
		ObservedAt: now.Add(-2 * time.Minute),
		Latitude:   30.7217,
		Longitude:  -97.3828,
	}
	legacy.Station = detail.Station
	legacy.Detail = &detail
	observations := make(map[string]time.Time, len(legacy.Components))
	for name, component := range legacy.Components {
		observations[name] = component.ObservedAt
	}
	legacy.Version = aggregateVersionWithDetail(observations, nil, detail)
	token, err := encodeAggregateSnapshot(legacy, aggregateSnapshotTestKey)
	if err != nil {
		t.Fatal(err)
	}
	payload := aggregateSnapshotPayload(t, token)
	if payload[0] != aggregateSnapshotSchemaV2 || len(payload) != aggregateSnapshotV2PayloadBytes {
		t.Fatalf("detail snapshot schema/length = %d/%d", payload[0], len(payload))
	}
	if len(token) > aggregateSnapshotMaxLength {
		t.Fatalf("detail snapshot token length = %d", len(token))
	}
	decoded, err := decodeAggregateSnapshot(token, legacy.Version, aggregateSnapshotTestKey, now)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.latest.Station != detail.Station || decoded.latest.Detail == nil || *decoded.latest.Detail != detail {
		t.Fatalf("decoded detail = %#v", decoded.latest.Detail)
	}

	for _, test := range []struct {
		name   string
		offset int
	}{
		{name: "station", offset: 57},
		{name: "scan", offset: 68},
		{name: "latitude", offset: 72},
		{name: "longitude", offset: 76},
	} {
		t.Run("tampered "+test.name, func(t *testing.T) {
			tamperedPayload := append([]byte(nil), payload...)
			tamperedPayload[test.offset] ^= 1
			if _, err := decodeAggregateSnapshot(
				signedAggregateSnapshot(tamperedPayload, legacy.Version, aggregateSnapshotTestKey),
				legacy.Version,
				aggregateSnapshotTestKey,
				now,
			); err == nil {
				t.Fatalf("tampered detail %s was accepted", test.name)
			}
		})
	}
}

func TestAggregateSnapshotValidatesFutureExpiryAndMissingMask(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	future := aggregateSnapshotFixture(now.Add(aggregateSnapshotFutureClockSkew + time.Minute))
	futureToken, err := encodeAggregateSnapshot(future, aggregateSnapshotTestKey)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := decodeAggregateSnapshot(futureToken, future.Version, aggregateSnapshotTestKey, now); err == nil {
		t.Fatal("expected future snapshot to be rejected")
	}

	expired := aggregateSnapshotFixture(now.Add(-tileGenerationGrace - time.Minute))
	expiredToken, err := encodeAggregateSnapshot(expired, aggregateSnapshotTestKey)
	if err != nil {
		t.Fatal(err)
	}
	decodedExpired, err := decodeAggregateSnapshot(expiredToken, expired.Version, aggregateSnapshotTestKey, now)
	if err != nil {
		t.Fatal(err)
	}
	if !decodedExpired.expired {
		t.Fatal("expected old snapshot to be marked expired")
	}

	missing := aggregateSnapshotFixture(now)
	delete(missing.Components, "guam")
	observations := make(map[string]time.Time, len(missing.Components))
	for name, component := range missing.Components {
		observations[name] = component.ObservedAt
	}
	missing.Version = aggregateVersion(observations, []string{"guam"})
	missingToken, err := encodeAggregateSnapshot(missing, aggregateSnapshotTestKey)
	if err != nil {
		t.Fatal(err)
	}
	decodedMissing, err := decodeAggregateSnapshot(missingToken, missing.Version, aggregateSnapshotTestKey, now)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := decodedMissing.latest.Components["guam"]; ok {
		t.Fatal("missing Guam region was restored by snapshot decode")
	}
	if len(decodedMissing.latest.MissingRegions) != 1 || decodedMissing.latest.MissingRegions[0] != "guam" {
		t.Fatalf("missing regions = %#v", decodedMissing.latest.MissingRegions)
	}
}

func aggregateSnapshotFixture(newest time.Time) Latest {
	components := make(map[string]LatestComponent, len(aggregateRegions))
	observations := make(map[string]time.Time, len(aggregateRegions))
	for index, region := range aggregateRegions {
		observedAt := newest.Add(-time.Duration(index) * time.Second).Add(125 * time.Millisecond)
		components[region.name] = LatestComponent{ObservedAt: observedAt}
		observations[region.name] = observedAt
	}
	return Latest{
		Product:    "aggregate",
		Station:    "conus",
		Elevation:  "0.5",
		ObservedAt: newest.Add(-4 * time.Second),
		Version:    aggregateVersion(observations, nil),
		Components: components,
	}
}

func aggregateSnapshotPayload(t *testing.T, token string) []byte {
	t.Helper()
	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		t.Fatalf("unexpected token %q", token)
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		t.Fatal(err)
	}
	return payload
}

func signedAggregateSnapshot(payload []byte, generation, key string) string {
	return base64.RawURLEncoding.EncodeToString(payload) + "." +
		base64.RawURLEncoding.EncodeToString(signAggregateSnapshot(payload, generation, key))
}
