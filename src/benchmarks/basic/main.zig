const std = @import("std");
const libz = @import("libz");
const zbench = @import("zbench");

const JobQueueConfig = libz.JobQueueConfig;
const JobQueue = libz.JobQueue;
const JobHandle = libz.JobHandle;

const Thread = std.Thread;
const ThreadPool = ThreadPool;

const Jobs = JobQueue(.{ .idle_sleep_ns = 10, .max_jobs_per_thread = std.math.maxInt(u11) });

// The allocator type won't matter for this test as we only allocate during init
var smpa = std.heap.smp_allocator;

// In order to improve performance for the std.Thread.Pool use the fixed buffer allocator
var ba_buffer: []u8 = undefined;
var ba: std.heap.FixedBufferAllocator = undefined;

var jobs: Jobs = undefined;
var std_thread_pool: Thread.Pool = undefined;

pub const Job = struct {
    pub fn exec(_: *Job) void {}
};

fn benchmarkLibZJobs(_: std.mem.Allocator) void {
    const root = jobs.allocate(Job{});
    jobs.schedule(root);
    for (0..Jobs.max_jobs_per_thread - 1) |_| {
        const handle = jobs.allocate(Job{});
        jobs.finishWith(handle, root);
        jobs.schedule(handle);
    }
    jobs.wait(root);
}

fn benchmarkStdFixedBufferAllocator(_: std.mem.Allocator) void {
    var job: Job = .{};
    var waitg = std.Thread.WaitGroup{};
    for (0..Jobs.max_jobs_per_thread) |_| {
        std_thread_pool.spawnWg(&waitg, Job.exec, .{&job});
    }
    std_thread_pool.waitAndWork(&waitg);
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var bench = zbench.Benchmark.init(std.heap.page_allocator, .{});
    defer bench.deinit();

    try stdout.print("\nScheduling {} empty jobs:\n", .{Jobs.max_jobs_per_thread});

    try bench.add("LibZ.Jobs", benchmarkLibZJobs, .{
        .hooks = .{
            .before_each = beforeEach,
            .after_each = afterEach,
        },
        .iterations = 100,
    });

    try bench.add("std.Thread.Pool: Fixed", benchmarkStdFixedBufferAllocator, .{
        .hooks = .{
            .before_each = beforeEachStdFixedBufferAllocator,
            .after_each = afterEachStdFixedBuffer,
        },
        .iterations = 100,
    });

    try bench.add("std.Thread.Pool: Smp ", benchmarkStdFixedBufferAllocator, .{
        .hooks = .{
            .before_each = beforeEachStdSmpAllocator,
            .after_each = afterEachStdSmpAllocator,
        },
        .iterations = 100,
    });

    try stdout.writeAll("\n");
    try bench.run(stdout);
}

pub fn beforeEach() void {
    jobs = Jobs.init(smpa) catch @panic("Out of Memory");
    jobs.start() catch @panic("Failed to start job system");
}

pub fn beforeEachStdFixedBufferAllocator() void {
    ba_buffer = smpa.alloc(u8, 128 * 2048) catch @panic("Out of Memory");
    ba = std.heap.FixedBufferAllocator.init(ba_buffer);
    std_thread_pool.init(.{
        .allocator = ba.allocator(),
    }) catch @panic("Unable to spawn std thread pool");
}

pub fn beforeEachStdSmpAllocator() void {
    std_thread_pool.init(.{
        .allocator = smpa,
    }) catch @panic("Unable to spawn std thread pool");
}

pub fn afterEach() void {
    jobs.stop();
    jobs.join();
    jobs.deinit();
}

pub fn afterEachStdFixedBuffer() void {
    std_thread_pool.deinit();
    smpa.free(ba_buffer);
}

pub fn afterEachStdSmpAllocator() void {
    std_thread_pool.deinit();
}
