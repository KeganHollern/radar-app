package lightning

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestProviderListsLiveWindowDownloadsExactObjectsAndRetriesFailures(t *testing.T) {
	now := time.Date(2026, 7, 18, 17, 0, 20, 0, time.UTC)
	oldKey := "GLM-L2-LCFA/2026/199/16/OR_GLM-L2-LCFA_G19_s20261991658200_e20261991658400_c20261991658417.nc"
	firstKey := "GLM-L2-LCFA/2026/199/16/OR_GLM-L2-LCFA_G19_s20261991659400_e20261991700000_c20261991700017.nc"
	secondKey := "GLM-L2-LCFA/2026/199/17/OR_GLM-L2-LCFA_G19_s20261991700000_e20261991700200_c20261991700217.nc"
	transport := &s3Transport{
		lists: map[string]string{
			"GLM-L2-LCFA/2026/199/16/": listXML(oldKey, firstKey, "GLM-L2-LCFA/2026/199/16/not-exact.nc"),
			"GLM-L2-LCFA/2026/199/17/": listXML(secondKey),
		},
		objects: map[string]string{firstKey: "first", secondKey: "second"},
	}
	decoder := &fakeDecoder{failOnce: map[string]bool{firstKey: true}, attempts: make(map[string]int)}
	service := NewService(ServiceOptions{Retention: 90 * time.Second, StaleAfter: 90 * time.Second})
	provider := NewProvider(ProviderOptions{
		Enabled:        true,
		EastBaseURL:    "https://east.test",
		WestBaseURL:    "https://west.test",
		Retention:      90 * time.Second,
		MaxObjectBytes: 1024,
		Client:         &http.Client{Transport: transport},
		Logger:         slog.New(slog.NewTextHandler(io.Discard, nil)),
		Service:        service,
		Decoder:        decoder,
		Now:            func() time.Time { return now },
	})

	err := provider.pollSource(context.Background(), source{id: "G19", baseURL: "https://east.test"}, now)
	if err == nil {
		t.Fatal("expected the first decode failure to be reported")
	}
	if decoder.attempts[firstKey] != 1 || decoder.attempts[secondKey] != 1 {
		t.Fatalf("decode attempts = %#v", decoder.attempts)
	}
	if transport.downloads[oldKey] != 0 || transport.downloads[secondKey] != 1 || transport.downloads[firstKey] != 1 {
		t.Fatalf("downloads = %#v", transport.downloads)
	}
	eastBounds, _ := ParseBounds("-104,20,-60,60")
	firstSnapshot := service.Snapshot(eastBounds, now)
	if !firstSnapshot.Available || len(firstSnapshot.Data.Features) != 1 || firstSnapshot.Data.Features[0].ID != secondKey {
		t.Fatalf("first snapshot = %#v", firstSnapshot)
	}

	if err := provider.pollSource(context.Background(), source{id: "G19", baseURL: "https://east.test"}, now); err != nil {
		t.Fatalf("retry poll failed: %v", err)
	}
	if decoder.attempts[firstKey] != 2 || decoder.attempts[secondKey] != 1 {
		t.Fatalf("retry attempts = %#v", decoder.attempts)
	}
	if transport.downloads[firstKey] != 2 || transport.downloads[secondKey] != 1 {
		t.Fatalf("retry downloads = %#v", transport.downloads)
	}
	if snapshot := service.Snapshot(eastBounds, now); len(snapshot.Data.Features) != 2 {
		t.Fatalf("snapshot after retry = %#v", snapshot)
	}

	if got := transport.listRequests; len(got) != 4 || got[0] != "GLM-L2-LCFA/2026/199/16/" || got[1] != "GLM-L2-LCFA/2026/199/17/" {
		t.Fatalf("list prefixes = %#v", got)
	}
}

func TestProviderDoesNotMarkUnavailableListAsChecked(t *testing.T) {
	now := time.Date(2026, 7, 18, 17, 10, 0, 0, time.UTC)
	service := NewService(ServiceOptions{})
	provider := NewProvider(ProviderOptions{
		Enabled:     true,
		EastBaseURL: "https://east.test",
		Retention:   time.Minute,
		Client: &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
			return nil, errors.New("offline")
		})},
		Service: service,
		Decoder: &fakeDecoder{},
	})
	if err := provider.pollSource(context.Background(), source{id: "G19", baseURL: "https://east.test"}, now); err == nil {
		t.Fatal("offline list unexpectedly succeeded")
	}
	if snapshot := service.Snapshot(nil, now); snapshot.Available || snapshot.CheckedAt != nil {
		t.Fatalf("unavailable source was marked checked: %#v", snapshot)
	}
}

func TestProviderDoesNotMarkRejectedIngestAsSeenOrHealthy(t *testing.T) {
	now := time.Date(2026, 7, 18, 17, 0, 20, 0, time.UTC)
	key := "GLM-L2-LCFA/2026/199/17/OR_GLM-L2-LCFA_G19_s20261991700000_e20261991700200_c20261991700217.nc"
	transport := &s3Transport{
		lists:   map[string]string{"GLM-L2-LCFA/2026/199/16/": listXML(), "GLM-L2-LCFA/2026/199/17/": listXML(key)},
		objects: map[string]string{key: "object"},
	}
	service := NewService(ServiceOptions{Retention: 90 * time.Second, StaleAfter: 90 * time.Second})
	// Simulate a provider whose local seen set was lost while its service still
	// owns the source object. Ingest must reject the duplicate, and the provider
	// must not convert that rejection into a successful seen entry.
	if !service.Ingest(Batch{Source: EastSourceID, ObjectKey: key, ObjectEnd: now}, now) {
		t.Fatal("test setup could not ingest object")
	}
	provider := NewProvider(ProviderOptions{
		Enabled:        true,
		EastBaseURL:    "https://east.test",
		Retention:      90 * time.Second,
		MaxObjectBytes: 1024,
		Client:         &http.Client{Transport: transport},
		Service:        service,
		Decoder:        &fakeDecoder{},
		Now:            func() time.Time { return now },
	})
	if err := provider.pollSource(context.Background(), source{id: EastSourceID, baseURL: "https://east.test"}, now); err == nil {
		t.Fatal("rejected service ingest was reported as success")
	}
	if provider.wasSeen(key) {
		t.Fatal("rejected service ingest was marked seen")
	}
	if transport.downloads[key] != 1 {
		t.Fatalf("downloads = %#v", transport.downloads)
	}
}

func TestProviderDecodeFailureDoesNotAdvanceProductHealth(t *testing.T) {
	now := time.Date(2026, 7, 18, 17, 0, 20, 0, time.UTC)
	key := "GLM-L2-LCFA/2026/199/17/OR_GLM-L2-LCFA_G19_s20261991700000_e20261991700200_c20261991700217.nc"
	transport := &s3Transport{
		lists:   map[string]string{"GLM-L2-LCFA/2026/199/16/": listXML(), "GLM-L2-LCFA/2026/199/17/": listXML(key)},
		objects: map[string]string{key: "object"},
	}
	decoder := &fakeDecoder{failOnce: map[string]bool{key: true}}
	service := NewService(ServiceOptions{Retention: 90 * time.Second, StaleAfter: 90 * time.Second})
	provider := NewProvider(ProviderOptions{
		Enabled:        true,
		EastBaseURL:    "https://east.test",
		Retention:      90 * time.Second,
		MaxObjectBytes: 1024,
		Client:         &http.Client{Transport: transport},
		Service:        service,
		Decoder:        decoder,
		Now:            func() time.Time { return now },
	})
	eastBounds, _ := ParseBounds("-100,20,-60,60")
	if err := provider.pollSource(context.Background(), source{id: EastSourceID, baseURL: "https://east.test"}, now); err == nil {
		t.Fatal("decode failure was not reported")
	}
	failed := service.Snapshot(eastBounds, now)
	if failed.Available || failed.ObservedAt != nil || failed.CheckedAt == nil || provider.wasSeen(key) {
		t.Fatalf("decode failure advanced health or seen state: snapshot=%#v seen=%v", failed, provider.wasSeen(key))
	}
	if err := provider.pollSource(context.Background(), source{id: EastSourceID, baseURL: "https://east.test"}, now); err != nil {
		t.Fatalf("retry failed: %v", err)
	}
	succeeded := service.Snapshot(eastBounds, now)
	if !succeeded.Available || succeeded.Stale || succeeded.ObservedAt == nil || !provider.wasSeen(key) {
		t.Fatalf("successful retry did not advance health: snapshot=%#v seen=%v", succeeded, provider.wasSeen(key))
	}
}

func TestLivePrefixesIncludePreviousHourOnlyWhenNeeded(t *testing.T) {
	withinHour := time.Date(2026, 7, 18, 17, 20, 0, 0, time.UTC)
	if prefixes := livePrefixes(withinHour, 90*time.Second); len(prefixes) != 1 || !strings.HasSuffix(prefixes[0], "/17/") {
		t.Fatalf("within-hour prefixes = %#v", prefixes)
	}
	nearBoundary := time.Date(2026, 7, 18, 17, 0, 20, 0, time.UTC)
	if prefixes := livePrefixes(nearBoundary, 90*time.Second); len(prefixes) != 2 || !strings.HasSuffix(prefixes[0], "/16/") || !strings.HasSuffix(prefixes[1], "/17/") {
		t.Fatalf("boundary prefixes = %#v", prefixes)
	}
}

type fakeDecoder struct {
	mu       sync.Mutex
	failOnce map[string]bool
	attempts map[string]int
}

func (d *fakeDecoder) Decode(_ []byte, object Object, receivedAt time.Time) ([]Flash, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.attempts == nil {
		d.attempts = make(map[string]int)
	}
	d.attempts[object.Key]++
	if d.failOnce[object.Key] && d.attempts[object.Key] == 1 {
		return nil, errors.New("temporary decode failure")
	}
	return []Flash{{ID: object.Key, Latitude: 30, Longitude: -90, ObservedAt: object.End, ReceivedAt: receivedAt, Satellite: SatelliteName(object.Satellite)}}, nil
}

type s3Transport struct {
	mu           sync.Mutex
	lists        map[string]string
	objects      map[string]string
	listRequests []string
	downloads    map[string]int
}

func (s *s3Transport) RoundTrip(request *http.Request) (*http.Response, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if request.URL.Query().Get("list-type") == "2" {
		prefix := request.URL.Query().Get("prefix")
		s.listRequests = append(s.listRequests, prefix)
		return testResponse(http.StatusOK, s.lists[prefix]), nil
	}
	key := strings.TrimPrefix(request.URL.Path, "/")
	if s.downloads == nil {
		s.downloads = make(map[string]int)
	}
	s.downloads[key]++
	body, found := s.objects[key]
	if !found {
		return testResponse(http.StatusNotFound, "missing"), nil
	}
	return testResponse(http.StatusOK, body), nil
}

func listXML(keys ...string) string {
	var builder strings.Builder
	builder.WriteString("<ListBucketResult><IsTruncated>false</IsTruncated>")
	for _, key := range keys {
		builder.WriteString("<Contents><Key>")
		builder.WriteString(key)
		builder.WriteString("</Key><Size>100</Size></Contents>")
	}
	builder.WriteString("</ListBucketResult>")
	return builder.String()
}

func testResponse(status int, body string) *http.Response {
	return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header), ContentLength: int64(len(body))}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (function roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return function(request)
}
