# ZLib.Jobs
A multithreaded job queue written in zig.

## Features
- Multithreaded job queue implementation.
- Job stealing.
- Lock free.

## Installation
build.zig.zon:
```zig
.dependencies = .{
    .jobs = .{
        .url = "https://github.com/ricknijhuis/LibZ.Jobs/archive/main.tar.gz",
        // .hash
    },
}
    
```
build.zig: 
```zig
const jobs_deb = b.dependency("jobs", .{
    .target = target,
    .optimize = optimize,
});
const jobs_mod = jobs_deb.module("ZLib.Jobs"); 
// add the import to the module where you need it.
your_mod.addImport("threading", jobs_mod);
```
## Usage/Examples

## JobQueue: Simple usage
Here we have a basic sample of how the job queue can be used.
```zig
    const testing = std.testing;
    const allocator = testing.allocator;

    // Defines the config for the jobs, available configs are:
    // - max_jobs_per_thread
    // - max_threads
    // - idle_sleep_ns
    const config: JobQueueConfig = .{
        .max_jobs_per_thread = 4,
    };
    // This preallocates the jobs per threads and the queues per thread
    var jobs = try JobQueue(config).init(allocator);
    // Don't forget to cleanup
    defer jobs.deinit();

    // Let's define a job, the job struct size can be at most 76 bytes, if more data is needed it
    // might be best to use a pointer to store to some allocated memory.
    const Job = struct {
        // this function is required. you can discard the parameter if not needed by using the _ syntax.
        pub fn exec(_: *@This()) void {
            std.debug.print("hello", .{});
        }
    };

    // Let's allocate our job, this is very fast as it uses a circular buffer pool to allocate
    // jobs from. Each thread has it's own pool so allocating can be done lock free.
    // Keep in mind that the 'max_jobs_per_thread' count is allocated per thread.
    // This will result in a memory footprint of:
    // 128(total job size) * max_jobs_per_thread * thread count
    const handle = jobs.allocate(Job{});

    // Now we schedule the job.
    // As soon as jobs.start is called it will be picked up by one of the threads.
    jobs.schedule(handle);

    // From this point onwards, any jobs scheduled will be picked up by one of the spawned threads.
    // You can pre-schedule some jobs and then call start but you can also call start first.
    // Is required to be called from the main thread.
    try jobs.start();

    // Here we make sure the job is completed until we continue,
    // while we are waiting this call might pickup other jobs so we do something useful while waiting.
    jobs.wait(handle);

    // Now we stop the threads from picking up other jobs. after this call we can join our threads.
    jobs.stop();

    // Here we call thread.join on all our threads,
    // if stop is not called it will block the calling thread indefinitely.
    // you can always call join though and call stop from another thread.
    // A nicer way to do this might be using something like:
    // defer jobs.join();
    // defer jobs.stop();
    jobs.join();
```

## JobQueue: continueJobs.
This sample shows how jobs can have other jobs that will continue it's work, this allows to split certain tasks
in more jobs than 1. The order of execution is defined by calling continueWith, here you basically say, once this job is done, continue with this job.
```zig
    const testing = std.testing;
    const allocator = testing.allocator;
    const config: JobQueueConfig = .{
        .max_jobs_per_thread = 4,
    };
    var jobs = try JobQueue(config).init(allocator);
    defer jobs.deinit();

    // This will be our starting jobs. our other jobs will be called after this one succeeded.
    const RootJob = struct {
        pub fn exec(_: *@This()) void {
            std.debug.print("Job: {s} executed\n", .{@typeName(@This())});
        }
    };

    // This job will run after RootJob
    const ContinueJob1 = struct {
        pub fn exec(_: *@This()) void {
            std.debug.print("Job: {s} executed\n", .{@typeName(@This())});
        }
    };

    // This job will run after Continue1Job
    const ContinueJob2 = struct {
        pub fn exec(_: *@This()) void {
            std.debug.print("Job: {s} executed\n", .{@typeName(@This())});
        }
    };

    const root = jobs.allocate(RootJob{});
    const continue1 = jobs.allocate(ContinueJob1{});
    const continue2 = jobs.allocate(ContinueJob2{});

    // Here we specify that continue1 job should be scheduled after root has been completed.
    // The job can still be picked up by any thread.
    // This can be done multiple times. The jobs will be scheduled in order of function call.
    jobs.continueWith(root, continue1);

    // Here we specify that continue2 job should run after continue1 job has been completed.
    jobs.continueWith(continue1, continue2);

    // We only need to schedule the root job, as once that is finished it will schedule all
    // continueWith jobs.
    jobs.schedule(root);

    // Now we startup the threads, they will pickup the root job.
    try jobs.start();

    defer jobs.join();
    defer jobs.stop();

    // Let's await the continue2 job, because we know this one will be scheduled after
    // the root and continue1 job have been completed, awaiting this will ensure all
    // jobs are done executing.
    jobs.wait(continue2);
```

## JobQueue: finishWith 
This sample shows how you can define a single job that you can use to await multiple jobs.
One use case for this could be updating a large buffer of data. you can split the buffer so each job can work on part of it.
but by using finishWith you can have a single job that you can await to know the entire buffer is updated.
```zig

    const testing = std.testing;
    const allocator = testing.allocator;
    const config: JobQueueConfig = .{
        .max_jobs_per_thread = 4,
    };
    var jobs = try JobQueue(config).init(allocator);
    defer jobs.deinit();

    var buffer: [256]u8 = undefined;

    const UpdateBufferJob = struct {
        value: u8,
        slice: []u8,
        pub fn exec(self: *@This()) void {
            @memset(self.slice, self.value);
        }
    };

    // Slice size for each job to work on.
    const size = buffer.len / config.max_jobs_per_thread;

    // Lets give the root job also something to do, it will update the first section of the buffer.
    const root = jobs.allocate(UpdateBufferJob{ .value = 0, .slice = buffer[0..size] });

    // We are still responsible of scheduling all the child jobs.
    // This is a very efficient way of scheduling them, this because we now can
    // already work on jobs while scheduling them on the main thread.
    // We skip 0 as that will be the parent job
    for (1..config.max_jobs_per_thread) |i| {
        const offset = size * i;
        const end = offset + size;
        const child = jobs.allocate(UpdateBufferJob{ .value = @intCast(i), .slice = buffer[offset..end] });
        // Here we basically say, if root is finished, so will this job.
        jobs.finishWith(child, root);
        // Let's schedule it so our worker threads can already pick it up while
        // we are continue scheduling on the main thread.
        jobs.schedule(child);
    }
    jobs.schedule(root);

    // We only need to await root here to ensure all child jobs have been finished.
    jobs.wait(root);
```
