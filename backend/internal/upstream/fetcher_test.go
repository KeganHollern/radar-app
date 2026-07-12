package upstream

import (
	"context"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/KeganHollern/radar-app/backend/internal/cache"
)

func TestFetcherCachesAndValidates(t *testing.T) {
	var calls atomic.Int32
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		calls.Add(1)
		if got := r.Header.Get("User-Agent"); got != "radar-test" {
			t.Errorf("user agent = %q", got)
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Status:     "200 OK",
			Header:     http.Header{"Content-Type": {"application/geo+json"}},
			Body:       io.NopCloser(strings.NewReader(`{"type":"FeatureCollection"}`)),
			Request:    r,
		}, nil
	})}

	fetcher := NewFetcher(client, cache.New(10, 1024), "radar-test", 1024, time.Minute)
	for range 2 {
		result, err := fetcher.Get(context.Background(), "alerts", "https://example.test/alerts", "application/geo+json", time.Minute, "application/geo+json")
		if err != nil {
			t.Fatal(err)
		}
		if len(result.Value.Body) == 0 {
			t.Fatal("empty body")
		}
	}
	if calls.Load() != 1 {
		t.Fatalf("upstream called %d times", calls.Load())
	}
}

func TestFetcherServesStaleOnInvalidUpstreamResponse(t *testing.T) {
	now := time.Now().UTC()
	responseCache := cache.New(10, 1024)
	responseCache.Put("tile", cache.Value{
		Body:       []byte("old png"),
		FetchedAt:  now.Add(-time.Minute),
		CheckedAt:  now.Add(-time.Minute),
		ExpiresAt:  now.Add(-time.Second),
		StaleUntil: now.Add(time.Minute),
	})
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusOK,
			Status:     "200 OK",
			Header:     http.Header{"Content-Type": {"text/html"}},
			Body:       io.NopCloser(strings.NewReader("temporary upstream error")),
			Request:    r,
		}, nil
	})}
	fetcher := NewFetcher(client, responseCache, "radar-test", 1024, time.Minute)
	result, err := fetcher.Get(context.Background(), "tile", "https://example.test/tile", "image/png", time.Minute, "image/png")
	if err != nil {
		t.Fatal(err)
	}
	if result.State != cache.Stale || string(result.Value.Body) != "old png" {
		t.Fatalf("unexpected stale result: %#v", result)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}
