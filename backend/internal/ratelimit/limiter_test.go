package ratelimit

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

func at(seconds float64) time.Time {
	return time.Unix(1780000000, 0).Add(time.Duration(seconds * float64(time.Second)))
}

func TestBucketStartsFull(t *testing.T) {
	t.Parallel()

	bucket := NewBucket(1, 5, at(0))

	// Five immediate requests must succeed. An empty starting bucket would reject a
	// device's first request after every restart, which is the moment it has the most to
	// send.
	for i := 0; i < 5; i++ {
		allowed, _ := bucket.Allow(at(0))
		if !allowed {
			t.Fatalf("request %d was refused from a full bucket", i+1)
		}
	}

	if allowed, _ := bucket.Allow(at(0)); allowed {
		t.Fatal("a sixth request was allowed from a bucket of five")
	}
}

func TestTokensAccrueContinuously(t *testing.T) {
	t.Parallel()

	bucket := NewBucket(2, 2, at(0))

	bucket.Allow(at(0))
	bucket.Allow(at(0))

	if allowed, _ := bucket.Allow(at(0)); allowed {
		t.Fatal("the bucket was not empty")
	}

	// Half a second at two per second is one token. Continuous accrual rather than a timer
	// means a fleet retrying in lockstep does not all land on the same tick.
	if allowed, _ := bucket.Allow(at(0.5)); !allowed {
		t.Fatal("a token had not accrued after half a second")
	}
}

func TestRefillIsCappedAtTheBurst(t *testing.T) {
	t.Parallel()

	bucket := NewBucket(10, 3, at(0))

	// An hour of idleness must not bank an hour of tokens. Otherwise a device that was
	// offline all morning returns and is allowed to do anything it likes.
	for i := 0; i < 3; i++ {
		if allowed, _ := bucket.Allow(at(3600)); !allowed {
			t.Fatalf("request %d refused after a long idle", i+1)
		}
	}
	if allowed, _ := bucket.Allow(at(3600)); allowed {
		t.Fatal("idleness banked more than the burst")
	}
}

func TestRetryAfterIsUseful(t *testing.T) {
	t.Parallel()

	bucket := NewBucket(2, 1, at(0))
	bucket.Allow(at(0))

	allowed, wait := bucket.Allow(at(0))
	if allowed {
		t.Fatal("expected a refusal")
	}

	// Half a second at two per second. A client told only "no" backs off blindly; one told
	// how long retries once, correctly.
	if wait < 400*time.Millisecond || wait > 600*time.Millisecond {
		t.Fatalf("expected roughly 500ms, got %v", wait)
	}
}

func TestClockGoingBackwardsDoesNotMintTokens(t *testing.T) {
	t.Parallel()

	bucket := NewBucket(1, 1, at(100))
	bucket.Allow(at(100))

	// Virtual machines move clocks backwards on migration. A bucket that refilled on a
	// negative interval would loosen precisely when the host is already struggling.
	if allowed, _ := bucket.Allow(at(50)); allowed {
		t.Fatal("a backwards clock refilled the bucket")
	}
}

func TestLimiterIsPerKey(t *testing.T) {
	t.Parallel()

	limiter := New(Config{PerSecond: 1, Burst: 1, Now: func() time.Time { return at(0) }})

	if allowed, _ := limiter.Allow("tenant-a"); !allowed {
		t.Fatal("tenant A was refused its first request")
	}
	if allowed, _ := limiter.Allow("tenant-a"); allowed {
		t.Fatal("tenant A exceeded its burst")
	}

	// One tenant exhausting its bucket must not affect another. This is the whole reason
	// the key is the tenant rather than the listener.
	if allowed, _ := limiter.Allow("tenant-b"); !allowed {
		t.Fatal("tenant B was refused because tenant A was noisy")
	}
}

func TestIdleKeysAreEvicted(t *testing.T) {
	t.Parallel()

	now := at(0)
	limiter := New(Config{
		PerSecond: 1, Burst: 1, MaxKeys: 3, IdleTTL: time.Minute,
		Now: func() time.Time { return now },
	})

	for i := 0; i < 3; i++ {
		limiter.Allow(fmt.Sprintf("tenant-%d", i))
	}
	if limiter.Len() != 3 {
		t.Fatalf("expected 3 keys, got %d", limiter.Len())
	}

	now = at(600)
	limiter.Allow("tenant-new")

	// Without eviction the map grows with every tenant that ever connects, and the leak
	// presents as a slow memory problem rather than as a rate limiting one.
	if limiter.Len() > 3 {
		t.Fatalf("idle keys were not evicted: %d keys", limiter.Len())
	}
}

func TestAFullTableStillServesANewTenant(t *testing.T) {
	t.Parallel()

	now := at(0)
	limiter := New(Config{
		PerSecond: 1, Burst: 1, MaxKeys: 2, IdleTTL: time.Hour,
		Now: func() time.Time { return now },
	})

	limiter.Allow("tenant-a")
	now = at(1)
	limiter.Allow("tenant-b")
	now = at(2)

	// Nothing is idle, so the table is genuinely full. A newcomer must still be served:
	// refusing it would turn a memory bound into a denial of service against a tenant that
	// has done nothing.
	if allowed, _ := limiter.Allow("tenant-c"); !allowed {
		t.Fatal("a new tenant was refused because the table was full")
	}
	if limiter.Len() > 2 {
		t.Fatalf("the table grew past its bound: %d", limiter.Len())
	}
}

func TestConcurrentCallersAreCountedExactly(t *testing.T) {
	limiter := New(Config{
		PerSecond: 0, Burst: 100,
		Now: func() time.Time { return at(0) },
	})

	var (
		wg      sync.WaitGroup
		mu      sync.Mutex
		allowed int
	)

	// Two hundred goroutines against a bucket of a hundred. Exactly a hundred must pass:
	// a limiter that is racy under contention is worthless, because contention is the only
	// condition it exists for.
	for i := 0; i < 200; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if ok, _ := limiter.Allow("tenant-a"); ok {
				mu.Lock()
				allowed++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()

	if allowed != 100 {
		t.Fatalf("allowed %d of 200 against a burst of 100", allowed)
	}
}

func BenchmarkAllowHot(b *testing.B) {
	limiter := New(Config{PerSecond: 1e9, Burst: 1e9})

	b.ReportAllocs()
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		limiter.Allow("tenant-a")
	}
}

func BenchmarkAllowContended(b *testing.B) {
	limiter := New(Config{PerSecond: 1e9, Burst: 1e9})

	b.ReportAllocs()
	b.ResetTimer()

	// The shape that matters: many goroutines, one key. If the map lock were held for the
	// whole operation this is where it would show.
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			limiter.Allow("tenant-a")
		}
	})
}

func BenchmarkAllowManyKeys(b *testing.B) {
	limiter := New(Config{PerSecond: 1e9, Burst: 1e9, MaxKeys: 1000})

	keys := make([]string, 1000)
	for i := range keys {
		keys[i] = fmt.Sprintf("tenant-%d", i)
	}

	b.ReportAllocs()
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		limiter.Allow(keys[i%len(keys)])
	}
}
