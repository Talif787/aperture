// Package ratelimit implements per-tenant token buckets.
//
// Written rather than taken from golang.org/x/time/rate, which would do this correctly and
// is barely a dependency. Two reasons it is worth the hundred lines here. The eviction
// policy is the part that actually matters at this scale and x/time/rate does not provide
// one, so a map of limiters keyed by tenant would grow without bound and the leak would
// look like a slow memory problem rather than a rate limiting problem. And this service
// has exactly one third-party dependency, which has been worth defending.
package ratelimit

import (
	"math"
	"sync"
	"time"
)

// Bucket is a token bucket.
//
// Tokens accrue continuously rather than being refilled on a timer. A timer would mean a
// device that retries in lockstep with the tick gets everything or nothing depending on
// where its retry lands, which is the kind of behaviour that turns a synchronised fleet
// into a thundering herd.
type Bucket struct {
	mu sync.Mutex

	// tokens is fractional. Integer tokens with a sub-second rate would round to zero and
	// the bucket would never refill.
	tokens   float64
	capacity float64
	perSecond float64
	last     time.Time
}

// NewBucket returns a bucket that starts full.
//
// Full rather than empty, because an empty bucket would reject a device's first request
// after a restart. The burst is what absorbs a fleet reconnecting at shift end, which is
// the load pattern this product actually has.
func NewBucket(perSecond float64, burst int, now time.Time) *Bucket {
	return &Bucket{
		tokens:    float64(burst),
		capacity:  float64(burst),
		perSecond: perSecond,
		last:      now,
	}
}

// Allow consumes one token if any remain, reporting how long until the next one.
//
// The wait is returned even when the request is allowed, so a caller can advertise it
// before a client has to guess. A client told only "no" backs off blindly; a client told
// "no, try in 400ms" retries once, correctly.
func (b *Bucket) Allow(now time.Time) (bool, time.Duration) {
	b.mu.Lock()
	defer b.mu.Unlock()

	b.refill(now)

	if b.tokens >= 1 {
		b.tokens--
		return true, 0
	}

	// Time to accrue the fraction of a token still missing.
	missing := 1 - b.tokens
	seconds := missing / b.perSecond

	return false, time.Duration(seconds * float64(time.Second))
}

func (b *Bucket) refill(now time.Time) {
	elapsed := now.Sub(b.last)

	// A clock that moved backwards must not mint tokens. Virtual machines do this on
	// migration, and the result would be a bucket that refills faster than configured
	// precisely when the host is already under stress.
	if elapsed <= 0 {
		b.last = now
		return
	}

	b.tokens = math.Min(b.capacity, b.tokens+elapsed.Seconds()*b.perSecond)
	b.last = now
}

// Idle reports how long since the bucket was last touched.
func (b *Bucket) Idle(now time.Time) time.Duration {
	b.mu.Lock()
	defer b.mu.Unlock()

	return now.Sub(b.last)
}
