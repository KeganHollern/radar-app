package cache

import (
	"container/list"
	"sync"
	"time"
)

type Value struct {
	Body         []byte
	ContentType  string
	ETag         string
	LastModified string
	FetchedAt    time.Time
	CheckedAt    time.Time
	ExpiresAt    time.Time
	StaleUntil   time.Time
}

type State string

const (
	Miss  State = "MISS"
	Hit   State = "HIT"
	Stale State = "STALE"
)

type item struct {
	key   string
	value Value
	size  int64
}

type Cache struct {
	mu         sync.Mutex
	items      map[string]*list.Element
	lru        *list.List
	maxEntries int
	maxBytes   int64
	bytes      int64
}

func New(maxEntries int, maxBytes int64) *Cache {
	return &Cache{
		items:      make(map[string]*list.Element),
		lru:        list.New(),
		maxEntries: maxEntries,
		maxBytes:   maxBytes,
	}
}

func (c *Cache) Get(key string, now time.Time) (Value, State, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	element, ok := c.items[key]
	if !ok {
		return Value{}, Miss, false
	}
	c.lru.MoveToFront(element)
	value := element.Value.(*item).value
	if now.Before(value.ExpiresAt) {
		return value, Hit, true
	}
	if now.Before(value.StaleUntil) {
		return value, Stale, true
	}
	c.remove(element)
	return Value{}, Miss, false
}

func (c *Cache) Put(key string, value Value) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if existing, ok := c.items[key]; ok {
		c.remove(existing)
	}
	size := int64(len(key) + len(value.Body) + len(value.ContentType) + len(value.ETag) + len(value.LastModified))
	if size > c.maxBytes {
		return
	}
	element := c.lru.PushFront(&item{key: key, value: value, size: size})
	c.items[key] = element
	c.bytes += size
	for len(c.items) > c.maxEntries || c.bytes > c.maxBytes {
		c.remove(c.lru.Back())
	}
}

func (c *Cache) remove(element *list.Element) {
	if element == nil {
		return
	}
	entry := element.Value.(*item)
	delete(c.items, entry.key)
	c.bytes -= entry.size
	c.lru.Remove(element)
}
