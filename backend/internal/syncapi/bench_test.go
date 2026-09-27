package syncapi

import (
	"context"
	"fmt"
	"testing"
	"time"
)

// Benchmarks exist to make a later change's cost visible, not to produce a number for a
// slide. The paths chosen are the ones every request goes through, so a regression in any
// of them is a regression in the whole service.

func benchService(b *testing.B) (*Service, context.Context) {
	b.Helper()

	now := func() time.Time { return time.Unix(1780000000, 0) }
	service := NewService(NewInMemoryStore(now), now)

	ctx := scoped(tenantA)
	return service, ctx
}

func BenchmarkPushApply(b *testing.B) {
	service, ctx := benchService(b)

	b.ReportAllocs()
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		_, _ = service.Push(ctx, PushRequest{Operations: []Operation{
			operation(fmt.Sprintf("op-%d", i), fmt.Sprintf("f-%d", i), 0, "note"),
		}})
	}
}

func BenchmarkPushReplay(b *testing.B) {
	service, ctx := benchService(b)

	// The same operation every time. A retry storm is the load this path actually sees,
	// so the replay lookup matters more than the apply.
	op := operation("op-replay", "f-replay", 0, "note")
	_, _ = service.Push(ctx, PushRequest{Operations: []Operation{op}})

	b.ReportAllocs()
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		_, _ = service.Push(ctx, PushRequest{Operations: []Operation{op}})
	}
}

func BenchmarkPullPage(b *testing.B) {
	service, ctx := benchService(b)

	for i := 0; i < 1000; i++ {
		_, _ = service.Push(ctx, PushRequest{Operations: []Operation{
			operation(fmt.Sprintf("seed-%d", i), fmt.Sprintf("f-%d", i), 0, "note"),
		}})
	}

	b.ReportAllocs()
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		_, _ = service.Pull(ctx, PullRequest{Limit: 100})
	}
}

func BenchmarkDecodeCursor(b *testing.B) {
	b.ReportAllocs()
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		_, _ = DecodeCursor("1234567")
	}
}
