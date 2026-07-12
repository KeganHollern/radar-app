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
