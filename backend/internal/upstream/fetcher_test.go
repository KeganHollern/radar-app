package upstream

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"sync"
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

func TestFetcherRefreshBypassesFreshCache(t *testing.T) {
	var calls atomic.Int32
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		call := calls.Add(1)
		if call == 2 && r.Header.Get("Cache-Control") != "no-cache" {
			t.Errorf("refresh cache control = %q", r.Header.Get("Cache-Control"))
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Status:     "200 OK",
			Header:     http.Header{"Content-Type": {"application/xml"}},
			Body:       io.NopCloser(strings.NewReader("version-" + string(rune('0'+call)))),
			Request:    r,
		}, nil
	})}
	fetcher := NewFetcher(client, cache.New(10, 1024), "radar-test", 1024, time.Minute)

	first, err := fetcher.Get(context.Background(), "capabilities", "https://example.test/capabilities", "application/xml", time.Minute, "application/xml")
	if err != nil {
		t.Fatal(err)
	}
	if string(first.Value.Body) != "version-1" {
		t.Fatalf("first body = %q", first.Value.Body)
	}
	refreshed, err := fetcher.Refresh(context.Background(), "capabilities", "https://example.test/capabilities", "application/xml", time.Minute, "application/xml")
	if err != nil {
		t.Fatal(err)
	}
	if string(refreshed.Value.Body) != "version-2" || calls.Load() != 2 {
		t.Fatalf("refresh body = %q, calls = %d", refreshed.Value.Body, calls.Load())
	}
	cached, err := fetcher.Get(context.Background(), "capabilities", "https://example.test/capabilities", "application/xml", time.Minute, "application/xml")
	if err != nil {
		t.Fatal(err)
	}
	if string(cached.Value.Body) != "version-2" || calls.Load() != 2 {
		t.Fatalf("cached body = %q, calls = %d", cached.Value.Body, calls.Load())
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

func TestFetcherDeriveCachesAndCoalescesBuilds(t *testing.T) {
	fetcher := NewFetcher(http.DefaultClient, cache.New(32, 1<<20), "radar-test", 1<<20, time.Minute)
	started := make(chan struct{})
	release := make(chan struct{})
	var startOnce sync.Once
	var builds atomic.Int32
	build := func(context.Context) (Result, error) {
		builds.Add(1)
		startOnce.Do(func() { close(started) })
		<-release
		return Result{Value: cache.Value{Body: []byte("derived")}}, nil
	}

	const callers = 16
	results := make(chan Result, callers)
	errors := make(chan error, callers)
	var wait sync.WaitGroup
	wait.Add(callers)
	for range callers {
		go func() {
			defer wait.Done()
			result, err := fetcher.Derive(context.Background(), "composite", time.Minute, "image/png", build)
			results <- result
			errors <- err
		}()
	}
	<-started
	close(release)
	wait.Wait()
	close(results)
	close(errors)
	for err := range errors {
		if err != nil {
			t.Fatal(err)
		}
	}
	for result := range results {
		if string(result.Value.Body) != "derived" || result.Value.ContentType != "image/png" {
			t.Fatalf("unexpected derived result: %#v", result)
		}
	}
	if builds.Load() != 1 {
		t.Fatalf("derived value built %d times, want 1", builds.Load())
	}

	cached, err := fetcher.Derive(context.Background(), "composite", time.Minute, "image/png", build)
	if err != nil {
		t.Fatal(err)
	}
	if cached.State != cache.Hit || builds.Load() != 1 {
		t.Fatalf("cached derived result state = %q, builds = %d", cached.State, builds.Load())
	}
}

func TestFetcherDeriveVersionedReplacesOneStableCacheSlot(t *testing.T) {
	responseCache := cache.New(1, 1<<20)
	fetcher := NewFetcher(http.DefaultClient, responseCache, "radar-test", 1<<20, time.Minute)
	var builds atomic.Int32
	checkedAt := time.Now().UTC()
	build := func(version string, checked time.Time) func(context.Context) (Result, error) {
		return func(context.Context) (Result, error) {
			builds.Add(1)
			return Result{Value: cache.Value{
				Body:      []byte(version),
				FetchedAt: checked,
				CheckedAt: checked,
			}}, nil
		}
	}

	if _, err := fetcher.DeriveVersioned(context.Background(), "alerts", "v1", time.Minute, "application/json", build("v1", checkedAt)); err != nil {
		t.Fatal(err)
	}
	if _, err := fetcher.DeriveVersioned(context.Background(), "alerts", "v2", time.Minute, "application/json", build("v2", checkedAt.Add(time.Second))); err != nil {
		t.Fatal(err)
	}

	cached, ok := fetcher.Cached("alerts")
	if !ok {
		t.Fatal("stable derived cache slot is missing")
	}
	if cached.Value.SourceVersion != "v2" || string(cached.Value.Body) != "v2" {
		t.Fatalf("cached version = %q body = %q", cached.Value.SourceVersion, cached.Value.Body)
	}
	if builds.Load() != 2 {
		t.Fatalf("versioned builds = %d, want 2", builds.Load())
	}
}

func TestFetcherDeriveVersionedWaiterSurvivesOwnerCancellation(t *testing.T) {
	fetcher := NewFetcher(http.DefaultClient, cache.New(8, 1<<20), "radar-test", 1<<20, time.Minute)
	started := make(chan struct{})
	release := make(chan struct{})
	ownerCtx, cancelOwner := context.WithCancel(context.Background())
	ownerError := make(chan error, 1)
	go func() {
		_, err := fetcher.DeriveVersioned(ownerCtx, "alerts", "v1", time.Minute, "application/json", func(context.Context) (Result, error) {
			close(started)
			<-release
			return Result{Value: cache.Value{Body: []byte("v1"), CheckedAt: time.Unix(1, 0)}}, nil
		})
		ownerError <- err
	}()
	<-started

	waiterResult := make(chan Result, 1)
	waiterError := make(chan error, 1)
	go func() {
		result, err := fetcher.DeriveVersioned(context.Background(), "alerts", "v2", time.Minute, "application/json", func(context.Context) (Result, error) {
			return Result{Value: cache.Value{Body: []byte("v2"), CheckedAt: time.Unix(2, 0)}}, nil
		})
		waiterResult <- result
		waiterError <- err
	}()

	cancelOwner()
	if err := <-ownerError; !errors.Is(err, context.Canceled) {
		t.Fatalf("owner error = %v, want context cancellation", err)
	}
	close(release)

	select {
	case err := <-waiterError:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("waiter remained blocked after detached owner build completed")
	}
	result := <-waiterResult
	if result.Value.SourceVersion != "v2" || string(result.Value.Body) != "v2" {
		t.Fatalf("waiter received version = %q body = %q", result.Value.SourceVersion, result.Value.Body)
	}
}

func TestFetcherDeriveVersionedFailureReturnsPriorVersionAsStale(t *testing.T) {
	fetcher := NewFetcher(http.DefaultClient, cache.New(8, 1<<20), "radar-test", 1<<20, time.Minute)
	checkedAt := time.Unix(100, 0).UTC()
	_, err := fetcher.DeriveVersioned(context.Background(), "alerts", "v1", time.Minute, "application/json", func(context.Context) (Result, error) {
		return Result{Value: cache.Value{Body: []byte("last good"), FetchedAt: checkedAt, CheckedAt: checkedAt}}, nil
	})
	if err != nil {
		t.Fatal(err)
	}

	fallback, err := fetcher.DeriveVersioned(context.Background(), "alerts", "v2", time.Minute, "application/json", func(context.Context) (Result, error) {
		return Result{}, errors.New("invalid source")
	})
	if err != nil {
		t.Fatal(err)
	}
	if fallback.State != cache.Stale || fallback.Value.SourceVersion != "v1" || string(fallback.Value.Body) != "last good" {
		t.Fatalf("fallback = %#v", fallback)
	}
	if !fallback.Value.CheckedAt.Equal(checkedAt) || !fallback.Value.FetchedAt.Equal(checkedAt) {
		t.Fatalf("fallback provenance changed: %#v", fallback.Value)
	}
}

func TestFetcherDeriveVersionedRejectsOlderOverwrite(t *testing.T) {
	fetcher := NewFetcher(http.DefaultClient, cache.New(8, 1<<20), "radar-test", 1<<20, time.Minute)
	newer := time.Unix(200, 0).UTC()
	if _, err := fetcher.DeriveVersioned(context.Background(), "alerts", "v2", time.Minute, "application/json", func(context.Context) (Result, error) {
		return Result{Value: cache.Value{Body: []byte("new"), FetchedAt: newer, CheckedAt: newer}}, nil
	}); err != nil {
		t.Fatal(err)
	}

	_, err := fetcher.DeriveVersioned(context.Background(), "alerts", "v1", time.Minute, "application/json", func(context.Context) (Result, error) {
		older := newer.Add(-time.Minute)
		return Result{Value: cache.Value{Body: []byte("old"), FetchedAt: older, CheckedAt: older}}, nil
	})
	if err == nil || !strings.Contains(err.Error(), "superseded") {
		t.Fatalf("older overwrite error = %v", err)
	}
	cached, ok := fetcher.Cached("alerts")
	if !ok || cached.Value.SourceVersion != "v2" || string(cached.Value.Body) != "new" {
		t.Fatalf("newer cached result was replaced: %#v, ok=%v", cached, ok)
	}
}

func TestFetcherDeriveVersionedSameRevisionFailureReturnsStale(t *testing.T) {
	fetcher := NewFetcher(http.DefaultClient, cache.New(8, 1<<20), "radar-test", 1<<20, time.Minute)
	if _, err := fetcher.DeriveVersioned(context.Background(), "alerts", "v1", 0, "application/json", func(context.Context) (Result, error) {
		return Result{Value: cache.Value{Body: []byte("last good")}}, nil
	}); err != nil {
		t.Fatal(err)
	}
	result, err := fetcher.DeriveVersioned(context.Background(), "alerts", "v1", 0, "application/json", func(context.Context) (Result, error) {
		return Result{}, errors.New("temporary build failure")
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.State != cache.Stale || result.Value.SourceVersion != "v1" || string(result.Value.Body) != "last good" {
		t.Fatalf("same-version stale fallback = %#v", result)
	}
}

func TestFetcherDeriveVersionedRecoversBuildPanicAndUnblocksNextCall(t *testing.T) {
	fetcher := NewFetcher(http.DefaultClient, cache.New(8, 1<<20), "radar-test", 1<<20, time.Minute)
	_, err := fetcher.DeriveVersioned(context.Background(), "alerts", "v1", time.Minute, "application/json", func(context.Context) (Result, error) {
		panic("boom")
	})
	if err == nil || !strings.Contains(err.Error(), "panicked") {
		t.Fatalf("panic error = %v", err)
	}

	result, err := fetcher.DeriveVersioned(context.Background(), "alerts", "v1", time.Minute, "application/json", func(context.Context) (Result, error) {
		return Result{Value: cache.Value{Body: []byte("recovered")}}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if string(result.Value.Body) != "recovered" || result.Value.SourceVersion != "v1" {
		t.Fatalf("result after panic = %#v", result)
	}
}

func TestFetcherDeriveVersionedReturnsSuccessfulOversizedBuild(t *testing.T) {
	fetcher := NewFetcher(http.DefaultClient, cache.New(1, 1), "radar-test", 1<<20, time.Minute)
	result, err := fetcher.DeriveVersioned(context.Background(), "alerts", "v1", time.Minute, "application/json", func(context.Context) (Result, error) {
		return Result{Value: cache.Value{Body: []byte("larger than cache")}}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if string(result.Value.Body) != "larger than cache" || result.Value.SourceVersion != "v1" {
		t.Fatalf("oversized build result = %#v", result)
	}
	if _, ok := fetcher.Cached("alerts"); ok {
		t.Fatal("oversized derived body unexpectedly entered the cache")
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}
