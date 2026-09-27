package ratelimit

import (
	"sync"
	"time"
)

// Limiter holds one bucket per key, with bounded memory.
//
// Per tenant, not per address. Inspectors in the field share a carrier NAT or a site's
// single uplink, so limiting by address throttles an entire crew because one device
// misbehaved. The tenant comes from a verified token, which also means a caller cannot
// escape its own limit by changing anything it controls.
type Limiter struct {
	mu      sync.Mutex
	buckets map[string]*Bucket

	perSecond float64
	burst     int

	// maxKeys bounds memory. Beyond it, the least recently used key is evicted rather than
	// the new one refused: a full table must not become a way to deny service to a tenant
	// that has not arrived yet.
	maxKeys int

	// idleTTL evicts keys nobody is using. A tenant that stops sending gets its bucket
	// back to full over the TTL anyway, so keeping the entry buys nothing.
	idleTTL time.Duration

	now func() time.Time
}

// Config describes a limiter.
type Config struct {
	PerSecond float64
	Burst     int
	MaxKeys   int
	IdleTTL   time.Duration
	Now       func() time.Time
}

// New builds a limiter, filling in defaults.
func New(config Config) *Limiter {
	if config.MaxKeys <= 0 {
		config.MaxKeys = 10000
	}
	if config.IdleTTL <= 0 {
		config.IdleTTL = 10 * time.Minute
	}
	if config.Now == nil {
		config.Now = time.Now
	}
	if config.Burst <= 0 {
		config.Burst = 1
	}

	return &Limiter{
		buckets:   make(map[string]*Bucket),
		perSecond: config.PerSecond,
		burst:     config.Burst,
		maxKeys:   config.MaxKeys,
		idleTTL:   config.IdleTTL,
		now:       config.Now,
	}
}

// Allow reports whether one request for this key may proceed.
func (l *Limiter) Allow(key string) (bool, time.Duration) {
	now := l.now()

	l.mu.Lock()

	bucket, found := l.buckets[key]
	if !found {
		if len(l.buckets) >= l.maxKeys {
			l.evict(now)
		}
		bucket = NewBucket(l.perSecond, l.burst, now)
		l.buckets[key] = bucket
	}

	l.mu.Unlock()

	// The bucket has its own lock, so one tenant's contention does not serialize every
	// other tenant behind the map lock.
	return bucket.Allow(now)
}

// evict removes idle keys, and if none are idle, the single stalest one.
//
// Called with the map lock held.
func (l *Limiter) evict(now time.Time) {
	var (
		stalest    string
		stalestAge time.Duration
	)

	for key, bucket := range l.buckets {
		age := bucket.Idle(now)

		if age >= l.idleTTL {
			delete(l.buckets, key)
			continue
		}

		if age > stalestAge {
			stalest, stalestAge = key, age
		}
	}

	// Nothing was idle, so the table is genuinely full of active tenants. Dropping the
	// stalest keeps the newcomer served; it will be recreated full, which is a small
	// generosity rather than a bypass, because the burst is bounded.
	if len(l.buckets) >= l.maxKeys && stalest != "" {
		delete(l.buckets, stalest)
	}
}

// Len reports how many keys are tracked. For tests and for a gauge.
func (l *Limiter) Len() int {
	l.mu.Lock()
	defer l.mu.Unlock()

	return len(l.buckets)
}
