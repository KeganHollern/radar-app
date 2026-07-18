package upstream

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/KeganHollern/radar-app/backend/internal/cache"
)

type Result struct {
	Value cache.Value
	State cache.State
}

type Fetcher struct {
	client    *http.Client
	cache     *cache.Cache
	userAgent string
	maxBytes  int64
	staleTTL  time.Duration

	mu       sync.Mutex
	inflight map[string]*call
}

type call struct {
	done          chan struct{}
	result        Result
	err           error
	sourceVersion string
}

func NewFetcher(client *http.Client, responseCache *cache.Cache, userAgent string, maxBytes int64, staleTTL time.Duration) *Fetcher {
	return &Fetcher{
		client:    client,
		cache:     responseCache,
		userAgent: userAgent,
		maxBytes:  maxBytes,
		staleTTL:  staleTTL,
		inflight:  make(map[string]*call),
	}
}

// Cached returns a fresh cached response without triggering revalidation or an
// upstream request. The returned body must be treated as immutable.
func (f *Fetcher) Cached(key string) (Result, bool) {
	value, state, ok := f.cache.Get(key, time.Now().UTC())
	if !ok || state != cache.Hit {
		return Result{}, false
	}
	return Result{Value: value, State: state}, true
}

func (f *Fetcher) Get(ctx context.Context, key, target, accept string, ttl time.Duration, contentTypePrefixes ...string) (Result, error) {
	return f.get(ctx, key, target, accept, ttl, false, contentTypePrefixes)
}

// Refresh performs one conditional upstream recheck even when key is still
// fresh in the local cache. Forced refreshes coalesce separately from ordinary
// reads and update the same cached value.
func (f *Fetcher) Refresh(ctx context.Context, key, target, accept string, ttl time.Duration, contentTypePrefixes ...string) (Result, error) {
	return f.get(ctx, key, target, accept, ttl, true, contentTypePrefixes)
}

// Derive caches and coalesces a response computed from other fetched values.
// It is intended for bounded transformations such as compositing already
// validated radar tiles, where repeating image work for every cache hit would
// waste CPU even though the source generations are immutable in the key.
func (f *Fetcher) Derive(ctx context.Context, key string, ttl time.Duration, contentType string, build func(context.Context) (Result, error)) (Result, error) {
	now := time.Now().UTC()
	if value, state, ok := f.cache.Get(key, now); ok && state == cache.Hit {
		return Result{Value: value, State: cache.Hit}, nil
	}

	inflightKey := "derive:" + key
	f.mu.Lock()
	if current, ok := f.inflight[inflightKey]; ok {
		f.mu.Unlock()
		select {
		case <-ctx.Done():
			return Result{}, ctx.Err()
		case <-current.done:
			return current.result, current.err
		}
	}
	current := &call{done: make(chan struct{})}
	f.inflight[inflightKey] = current
	f.mu.Unlock()

	current.result, current.err = f.derive(ctx, key, ttl, contentType, build)
	close(current.done)
	f.mu.Lock()
	delete(f.inflight, inflightKey)
	f.mu.Unlock()
	return current.result, current.err
}

// DeriveVersioned keeps one derived cache slot for a logical key while making
// the source revision part of its freshness check. Builds for different source
// revisions serialize on the stable key, and waiters always re-check their own
// requested revision after the shared build completes.
//
// The shared build is detached from the first waiter's cancellation. Callers
// can stop waiting independently, while build must apply its own bounded
// timeout for any external work.
func (f *Fetcher) DeriveVersioned(
	ctx context.Context,
	key string,
	sourceVersion string,
	ttl time.Duration,
	contentType string,
	build func(context.Context) (Result, error),
) (Result, error) {
	if sourceVersion == "" {
		return Result{}, errors.New("derived source version must not be empty")
	}
	inflightKey := "derive-versioned:" + key
	for {
		now := time.Now().UTC()
		if value, state, ok := f.cache.Get(key, now); ok && state == cache.Hit && value.SourceVersion == sourceVersion {
			return Result{Value: value, State: cache.Hit}, nil
		}

		f.mu.Lock()
		current, exists := f.inflight[inflightKey]
		if !exists {
			current = &call{done: make(chan struct{}), sourceVersion: sourceVersion}
			f.inflight[inflightKey] = current
			buildCtx := context.WithoutCancel(ctx)
			go f.finishVersionedDerive(current, inflightKey, buildCtx, key, sourceVersion, ttl, contentType, build)
		}
		f.mu.Unlock()

		select {
		case <-ctx.Done():
			return Result{}, ctx.Err()
		case <-current.done:
			// A different source revision may have owned the shared build. Loop
			// through the cache check rather than accepting that result.
			if current.sourceVersion != sourceVersion {
				continue
			}
			if current.err != nil {
				return Result{}, current.err
			}
			if current.result.State == cache.Stale {
				return current.result, nil
			}
			if current.result.Value.SourceVersion != sourceVersion {
				// Cross-version fallback is intentionally usable only when it is
				// explicitly marked stale and retains the prior value's provenance.
				return Result{}, errors.New("derived result has an unexpected source version")
			}
			// Return the matching shared result directly. Cache admission is
			// deliberately best-effort, so an oversized value must not make a
			// successful caller rebuild forever.
			return current.result, nil
		}
	}
}

func (f *Fetcher) finishVersionedDerive(
	current *call,
	inflightKey string,
	ctx context.Context,
	key string,
	sourceVersion string,
	ttl time.Duration,
	contentType string,
	build func(context.Context) (Result, error),
) {
	defer func() {
		if recovered := recover(); recovered != nil {
			current.result = Result{}
			current.err = fmt.Errorf("versioned derived build panicked: %v", recovered)
		}
		f.mu.Lock()
		if f.inflight[inflightKey] == current {
			delete(f.inflight, inflightKey)
		}
		f.mu.Unlock()
		close(current.done)
	}()
	current.result, current.err = f.deriveVersioned(ctx, key, sourceVersion, ttl, contentType, build)
}

func (f *Fetcher) deriveVersioned(
	ctx context.Context,
	key string,
	sourceVersion string,
	ttl time.Duration,
	contentType string,
	build func(context.Context) (Result, error),
) (Result, error) {
	now := time.Now().UTC()
	previous, previousState, hasPrevious := f.cache.Get(key, now)
	if hasPrevious && previousState == cache.Hit && previous.SourceVersion == sourceVersion {
		return Result{Value: previous, State: cache.Hit}, nil
	}

	result, err := build(ctx)
	if err != nil {
		if hasPrevious && previous.SourceVersion != "" {
			return Result{Value: previous, State: cache.Stale}, nil
		}
		return Result{}, err
	}

	now = time.Now().UTC()
	result.Value.ContentType = contentType
	result.Value.ETag = ""
	result.Value.SourceVersion = sourceVersion
	if result.Value.FetchedAt.IsZero() {
		result.Value.FetchedAt = now
	}
	if result.Value.CheckedAt.IsZero() {
		result.Value.CheckedAt = now
	}
	result.Value.ExpiresAt = now.Add(ttl)
	result.Value.StaleUntil = now.Add(ttl + f.staleTTL)

	// A delayed request for an older source must not replace a newer revision
	// that reached the stable slot while this caller was waiting elsewhere.
	if existing, _, ok := f.cache.Get(key, now); ok &&
		existing.SourceVersion != "" &&
		existing.SourceVersion != sourceVersion &&
		newerProvenance(existing, result.Value) {
		return Result{}, errors.New("derived source version was superseded")
	}

	f.cache.Put(key, result.Value)
	if result.State == "" {
		result.State = cache.Miss
	}
	return result, nil
}

func newerProvenance(existing, candidate cache.Value) bool {
	if existing.CheckedAt.After(candidate.CheckedAt) {
		return true
	}
	return existing.CheckedAt.Equal(candidate.CheckedAt) && existing.FetchedAt.After(candidate.FetchedAt)
}

func (f *Fetcher) derive(ctx context.Context, key string, ttl time.Duration, contentType string, build func(context.Context) (Result, error)) (Result, error) {
	now := time.Now().UTC()
	staleValue, staleState, hasStale := f.cache.Get(key, now)
	if hasStale && staleState == cache.Hit {
		return Result{Value: staleValue, State: cache.Hit}, nil
	}

	result, err := build(ctx)
	if err != nil {
		if hasStale && staleState == cache.Stale {
			return Result{Value: staleValue, State: cache.Stale}, nil
		}
		return Result{}, err
	}
	now = time.Now().UTC()
	result.Value.ContentType = contentType
	result.Value.ETag = ""
	result.Value.LastModified = ""
	result.Value.FetchedAt = now
	result.Value.CheckedAt = now
	result.Value.ExpiresAt = now.Add(ttl)
	result.Value.StaleUntil = now.Add(ttl + f.staleTTL)
	f.cache.Put(key, result.Value)
	if result.State == "" {
		result.State = cache.Miss
	}
	return result, nil
}

func (f *Fetcher) get(ctx context.Context, key, target, accept string, ttl time.Duration, force bool, contentTypePrefixes []string) (Result, error) {
	now := time.Now().UTC()
	if value, state, ok := f.cache.Get(key, now); !force && ok && state == cache.Hit {
		return Result{Value: value, State: cache.Hit}, nil
	}

	inflightKey := key
	if force {
		inflightKey = "refresh:" + key
	}
	f.mu.Lock()
	if current, ok := f.inflight[inflightKey]; ok {
		f.mu.Unlock()
		select {
		case <-ctx.Done():
			return Result{}, ctx.Err()
		case <-current.done:
			return current.result, current.err
		}
	}
	current := &call{done: make(chan struct{})}
	f.inflight[inflightKey] = current
	f.mu.Unlock()

	current.result, current.err = f.fetch(ctx, key, target, accept, ttl, force, contentTypePrefixes)
	close(current.done)
	f.mu.Lock()
	delete(f.inflight, inflightKey)
	f.mu.Unlock()
	return current.result, current.err
}

func (f *Fetcher) fetch(ctx context.Context, key, target, accept string, ttl time.Duration, force bool, contentTypePrefixes []string) (Result, error) {
	now := time.Now().UTC()
	staleValue, staleState, hasStale := f.cache.Get(key, now)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return Result{}, err
	}
	req.Header.Set("Accept", accept)
	req.Header.Set("User-Agent", f.userAgent)
	if force {
		req.Header.Set("Cache-Control", "no-cache")
	}
	if hasStale {
		if staleValue.ETag != "" {
			req.Header.Set("If-None-Match", staleValue.ETag)
		}
		if staleValue.LastModified != "" {
			req.Header.Set("If-Modified-Since", staleValue.LastModified)
		}
	}

	resp, err := f.client.Do(req)
	if err != nil {
		if hasStale && staleState == cache.Stale {
			return Result{Value: staleValue, State: cache.Stale}, nil
		}
		return Result{}, fmt.Errorf("fetch upstream: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotModified && hasStale {
		expires := now.Add(ttl)
		staleValue.CheckedAt = now
		staleValue.ExpiresAt = expires
		staleValue.StaleUntil = expires.Add(f.staleTTL)
		f.cache.Put(key, staleValue)
		return Result{Value: staleValue, State: cache.Hit}, nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		if hasStale && staleState == cache.Stale {
			return Result{Value: staleValue, State: cache.Stale}, nil
		}
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		return Result{}, fmt.Errorf("upstream returned %s", resp.Status)
	}

	contentType := resp.Header.Get("Content-Type")
	if !matchesContentType(contentType, contentTypePrefixes) {
		if hasStale && staleState == cache.Stale {
			return Result{Value: staleValue, State: cache.Stale}, nil
		}
		return Result{}, fmt.Errorf("unexpected upstream content type %q", contentType)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, f.maxBytes+1))
	if err != nil {
		if hasStale && staleState == cache.Stale {
			return Result{Value: staleValue, State: cache.Stale}, nil
		}
		return Result{}, fmt.Errorf("read upstream: %w", err)
	}
	if int64(len(body)) > f.maxBytes {
		if hasStale && staleState == cache.Stale {
			return Result{Value: staleValue, State: cache.Stale}, nil
		}
		return Result{}, errors.New("upstream response exceeds configured limit")
	}
	value := cache.Value{
		Body:         body,
		ContentType:  contentType,
		ETag:         resp.Header.Get("ETag"),
		LastModified: resp.Header.Get("Last-Modified"),
		FetchedAt:    now,
		CheckedAt:    now,
		ExpiresAt:    now.Add(ttl),
		StaleUntil:   now.Add(ttl + f.staleTTL),
	}
	f.cache.Put(key, value)
	return Result{Value: value, State: cache.Miss}, nil
}

func matchesContentType(value string, prefixes []string) bool {
	if len(prefixes) == 0 {
		return true
	}
	value = strings.ToLower(strings.TrimSpace(value))
	for _, prefix := range prefixes {
		if strings.HasPrefix(value, strings.ToLower(prefix)) {
			return true
		}
	}
	return false
}
