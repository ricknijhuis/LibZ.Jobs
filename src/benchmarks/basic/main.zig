const std = @import("std");
const libz = @import("libz");
const zbench = @import("zbench");

const JobQueueConfig = libz.JobQueueConfig;
const JobQueue = libz.JobQueue;
const JobHandle = libz.JobHandle;

const Thread = std.Thread;
const ThreadPool = ThreadPool;

const Jobs = JobQueue(.{ .max_jobs_per_thread = 2047 });

// The allocator type won't matter for this test as we only allocate during init
var da = std.heap.DebugAllocator(.{}){};

// In order to improve performance for the std.Thread.Pool use the fixed buffer allocator
var ba_buffer: []u8 = undefined;
var ba: std.heap.FixedBufferAllocator = undefined;

var jobs: Jobs = undefined;
var std_thread_pool: Thread.Pool = undefined;

pub var counter: u32 = undefined;

pub const Job = struct {
    pub fn exec(_: *Job) void {}
};

fn benchmarkLibZJobs(_: std.mem.Allocator) void {
    const handle = jobs.allocate(Job{});
    jobs.schedule(handle);
}

fn benchmarkDefaultThread(_: std.mem.Allocator) void {
    var job: Job = .{};
    std_thread_pool.spawn(Job.exec, .{&job}) catch @panic("Thread failed to spawn");
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var bench = zbench.Benchmark.init(std.heap.page_allocator, .{});
    defer bench.deinit();

    try bench.add("LibZ.Jobs", benchmarkLibZJobs, .{
        .hooks = .{
            .before_all = beforeAll,
            .after_all = afterAll,
        },
        .iterations = Jobs.max_jobs_per_thread,
    });

    try bench.add("std.Thread.Pool", benchmarkDefaultThread, .{
        .hooks = .{
            .before_all = beforeAllThreadPool,
            .after_all = afterAllThreadPool,
        },
        .iterations = Jobs.max_jobs_per_thread,
    });

    try stdout.writeAll("\n");
    try bench.run(stdout);
}

pub fn beforeAll() void {
    jobs = Jobs.init(da.allocator()) catch @panic("Out of Memory");
    jobs.start() catch @panic("Failed to start job system");
    counter = 0;
}

pub fn beforeAllThreadPool() void {
    ba_buffer = da.allocator().alloc(u8, 128 * 2048) catch @panic("Out of Memory");
    ba = std.heap.FixedBufferAllocator.init(ba_buffer);
    std_thread_pool.init(.{
        .allocator = ba.allocator(),
        .n_jobs = Jobs.max_jobs_per_thread,
    }) catch @panic("Unable to spawn std thread pool");
    counter = 0;
}

pub fn afterAll() void {
    jobs.stop();
    jobs.join();
    jobs.deinit();
    counter = 0;
}

pub fn afterAllThreadPool() void {
    std_thread_pool.deinit();
    da.allocator().free(ba_buffer);
    counter = 0;
}
