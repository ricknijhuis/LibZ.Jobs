const std = @import("std");
const libz = @import("libz");

const JobQueueConfig = libz.JobQueueConfig;
const JobQueue = libz.JobQueue(.{ .max_jobs_per_thread = std.math.maxInt(u11) });
const JobHandle = libz.JobHandle;

var count: u32 = 0;
const Job = struct {
    i: u32 = 0,
    pub fn exec(self: *@This()) void {
        self.i = @atomicLoad(u32, &count, .monotonic);

        // var prng = std.Random.DefaultPrng.init(self.i);
        // const rand = prng.random();
        // std.Thread.sleep(rand.intRangeAtMost(u64, std.time.ns_per_ms, std.time.ns_per_ms * 100));
        _ = @atomicRmw(u32, &count, .Add, 1, .monotonic);
    }
};

pub fn main() !void {
    std.log.info("Test", .{});
    var da = std.heap.DebugAllocator(.{}){};
    const allocator = da.allocator();

    var jobs = try JobQueue.init(allocator);
    defer jobs.deinit();

    const root = jobs.allocate(Job{});
    jobs.schedule(root);
    for (0..JobQueue.max_jobs_per_thread - 1) |_| {
        const handle = jobs.allocate(Job{});
        jobs.finishWith(handle, root);
        jobs.schedule(handle);
    }
    try jobs.start();
    defer jobs.join();
    defer jobs.stop();

    jobs.wait(root);
    std.log.info("{}", .{count});
}
