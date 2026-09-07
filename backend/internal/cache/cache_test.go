package cache

import (
	"testing"
	"time"
)

func TestCacheFreshStaleExpiredAndLRU(t *testing.T) {
	now := time.Unix(100, 0)
	c := New(1, 1024)
	c.Put("a", Value{Body: []byte("a"), ExpiresAt: now.Add(time.Second), StaleUntil: now.Add(2 * time.Second)})
	if _, state, ok := c.Get("a", now); !ok || state != Hit {
		t.Fatalf("wanted hit, got %s %v", state, ok)
	}
	if _, state, ok := c.Get("a", now.Add(1500*time.Millisecond)); !ok || state != Stale {
		t.Fatalf("wanted stale, got %s %v", state, ok)
	}
	if _, _, ok := c.Get("a", now.Add(3*time.Second)); ok {
		t.Fatal("wanted expired item removed")
	}
	c.Put("a", Value{Body: []byte("a"), ExpiresAt: now.Add(time.Hour), StaleUntil: now.Add(time.Hour)})
	c.Put("b", Value{Body: []byte("b"), ExpiresAt: now.Add(time.Hour), StaleUntil: now.Add(time.Hour)})
	if _, _, ok := c.Get("a", now); ok {
		t.Fatal("wanted least-recently-used item evicted")
	}
}

func TestCacheCountsSourceVersionTowardByteLimit(t *testing.T) {
	now := time.Now().UTC()
	c := New(1, 4)
	c.Put("k", Value{
		Body:          []byte("b"),
		SourceVersion: "rev",
		ExpiresAt:     now.Add(time.Minute),
		StaleUntil:    now.Add(time.Minute),
	})
	if _, _, ok := c.Get("k", now); ok {
		t.Fatal("entry exceeding the byte limit through its source revision was cached")
	}
}

func TestCachePurgeExpiredRemovesOneOffKeys(t *testing.T) {
	now := time.Unix(100, 0)
	c := New(4, 1024)
	c.Put("expired", Value{Body: []byte("old"), ExpiresAt: now, StaleUntil: now.Add(time.Second)})
	c.Put("current", Value{Body: []byte("new"), ExpiresAt: now.Add(time.Hour), StaleUntil: now.Add(time.Hour)})

	if removed := c.PurgeExpired(now.Add(2 * time.Second)); removed != 1 {
		t.Fatalf("removed %d entries, want 1", removed)
	}
	if _, _, ok := c.Get("expired", now); ok {
		t.Fatal("expired one-off key survived the purge")
	}
	if _, state, ok := c.Get("current", now); !ok || state != Hit {
		t.Fatalf("current entry was removed: state=%s ok=%v", state, ok)
	}

	c.Delete("current")
	if _, _, ok := c.Get("current", now); ok {
		t.Fatal("deleted entry remained in cache")
	}
}
