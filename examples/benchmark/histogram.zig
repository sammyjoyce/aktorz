const std = @import("std");

const Allocator = std.mem.Allocator;

pub const LatencyHistogram = struct {
    alloc: Allocator,
    counts: []u64,
    total_count: u64 = 0,

    const linear_limit_us: usize = 10_000;
    const extra_log_buckets: usize = 32;

    pub fn init(alloc: Allocator) !LatencyHistogram {
        const counts = try alloc.alloc(u64, linearLimitBucketCount() + extra_log_buckets);
        @memset(counts, 0);
        return .{
            .alloc = alloc,
            .counts = counts,
        };
    }

    pub fn deinit(self: *LatencyHistogram) void {
        self.alloc.free(self.counts);
        self.* = undefined;
    }

    pub fn reset(self: *LatencyHistogram) void {
        @memset(self.counts, 0);
        self.total_count = 0;
    }

    pub fn record(self: *LatencyHistogram, latency_ns: u64) void {
        const bucket = bucketIndex(latency_ns);
        self.counts[bucket] += 1;
        self.total_count += 1;
    }

    pub fn percentile(self: *const LatencyHistogram, pct: f64) u64 {
        if (self.total_count == 0) return 0;

        const clamped_pct = std.math.clamp(pct, 0.0, 100.0);
        const wanted = @max(
            @as(u64, 1),
            @as(u64, @intFromFloat(@ceil((@as(f64, @floatFromInt(self.total_count)) * clamped_pct) / 100.0))),
        );

        var seen: u64 = 0;
        for (self.counts, 0..) |count, index| {
            seen += count;
            if (seen >= wanted) return bucketUpperBoundNs(index);
        }

        return bucketUpperBoundNs(self.counts.len - 1);
    }

    fn bucketIndex(latency_ns: u64) usize {
        const latency_us = latency_ns / std.time.ns_per_us;
        if (latency_us <= linear_limit_us) return @intCast(latency_us);

        const delta = latency_us - linear_limit_us;
        const log_bucket = std.math.log2_int_ceil(u64, delta + 1);
        const capped_log_bucket = @min(log_bucket, extra_log_buckets - 1);
        return linearLimitBucketCount() + capped_log_bucket - 1;
    }

    fn bucketUpperBoundNs(index: usize) u64 {
        if (index < linearLimitBucketCount()) {
            return (@as(u64, @intCast(index)) + 1) * std.time.ns_per_us;
        }

        const log_bucket = index - linearLimitBucketCount() + 1;
        const delta_us = @as(u64, 1) << @intCast(log_bucket);
        return (@as(u64, linear_limit_us) + delta_us) * std.time.ns_per_us;
    }

    fn linearLimitBucketCount() usize {
        return linear_limit_us + 1;
    }
};
