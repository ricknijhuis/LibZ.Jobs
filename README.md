# LibZ.Jobs
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

## JobQueue: waitResult
Using 'waitResult' provides a way to get the data of the job, it will be copied and cast to
the provided type.
```zig
    const testing = std.testing;
    const allocator = testing.allocator;
    const config: JobQueueConfig = .{
        .max_jobs_per_thread = 4,
    };

    // We want the value of foo once this job is finished.
    const Job = struct {
        foo: u32 = 0,
        pub fn exec(self: *@This()) void {
            self.foo += 1;
        }
    };

    var jobs = try JobQueue(config).init(allocator);
    defer jobs.deinit();

    const handle = jobs.allocate(Job{});
    jobs.schedule(handle);

    try jobs.start();
    
    // Here we get the result from the job, it will be copied.
    // other ways of retrieving the members of a job would be
    // - calling 'wait' and after that calling 'result'
    // - using a pointer and define the data outside the job
    const result = jobs.waitResult(Job, handle);

    try testing.expectEqual(1, result.foo);

    defer jobs.join();
    defer jobs.stop();
```

# Benchmarking
Here are some benchmarks in comparison to the std.Thread.Pool.
All benchmark code can be found in the src/benchmarks directory and run using:
```shell
zig build benchmark -Dbenchmark=basic -Doptimize=ReleaseFast
```
Available benchmarks are:
- basic
- basic_ordered

For benchmarking the following library is used: [zBench](https://github.com/hendriknielaender/zBench)
All benchmarks are executed on the following system:
CPU: AMD Ryzen™ 7 5800X × 16
GPU: NVIDEA GTX1080TI
RAM: 32GB DDR4 2133 MHz

## Benchmark: Basic
Here we have the simplest of benchmark, allocate and schedule 2047 empty jobs.
Here we compare it with the std.Thread.Pool using a WaitGroup. This benchmark is meant to show the overhead
of allocating and scheduling jobs. As the LibZ jobs preallocates everything I tried making it as even as possible
by using a preallocated buffer with a std.heap.FixedBufferAllocator and also using the std.heap.SmpAllocator.
As shown here the allocator doesn't matter too much for the std implementation.

As the difference is very large I am curious to see if there is some improvements I could do in my usage with the std.Thread.Pool benchmark.

Scheduling 2048 empty jobs:
```shell
benchmark              runs     total time     time/run (avg ± σ)     (min ... max)                p75        p99        p995      
-----------------------------------------------------------------------------------------------------------------------------
LibZ.Jobs              100      12.593ms       125.931us ± 32.471us   (57.35us ... 187.639us)      158.009us  187.639us  187.639us 
std.Thread.Pool: Fixed 100      154.913ms      1.549ms ± 35.235us     (1.511ms ... 1.704ms)        1.555ms    1.704ms    1.704ms   
std.Thread.Pool: Smp   100      161.637ms      1.616ms ± 52.926us     (1.557ms ... 1.886ms)        1.622ms    1.886ms    1.886ms   
```   
Thread usage, count of jobs picked up per thread.   

LibZ:
| ThreadId | Count of jobs|
|----------|------------- |
| 38863            | 141      |
| 38864            | 257      |
| 38865            | 59       |
| 38866            | 202      |
| 38867            | 43       |
| 38868            | 199      |
| 38869            | 76       |
| 38870            | 105      |
| 38871            | 26       |
| 38872            | 54       |
| 38873            | 214      |
| 38874            | 88       |
| 38875            | 32       |
| 38876            | 219      |
| 38877            | 155      |
| 38878            | 145      |
| 38879            | 32       |
| **Total Result** | **2047** |

std.Thread.Pool
| ThreadId | Count of jobs|
|----------|------------- |
| 46420            | 73       |
| 46421            | 445      |
| 46422            | 101      |
| 46423            | 151      |
| 46424            | 159      |
| 46425            | 55       |
| 46426            | 41       |
| 46427            | 23       |
| 46428            | 60       |
| 46429            | 201      |
| 46430            | 110      |
| 46431            | 174      |
| 46432            | 146      |
| 46433            | 98       |
| 46434            | 77       |
| 46435            | 43       |
| 46436            | 90       |
| **Total Result** | **2047** |

See the code [here](src/benchmarks/basic/main.zig)

## Benchmark: Basic ordered
Here we have another very simple benchmark, for the std.Thread.Jobs the code is the same but now LibZ.Jobs schedules and directly awaits
the job. It seems weird that this can be faster than scheduling all of them and await them in one single go, but I assume the case here
is that because it's empty the overhead of popping and stealing from the queue will be less because there is no contention.

std.Thread.Pool WaitGroup does not allow this case, so here we show also a bit of the flexibility of the job system although
I am not entirely sure of the usecase of this :)

As the difference is very large I am curious to see if there is some improvements I could do in my usage with the std.Thread.Pool benchmark.

Scheduling 2048 empty jobs:
```shell
benchmark              runs     total time     time/run (avg ± σ)     (min ... max)                p75        p99        p995      
-----------------------------------------------------------------------------------------------------------------------------
LibZ.Jobs              100      4.279ms        42.798us ± 25.958us    (24.27us ... 140.699us)      37.709us   140.699us  140.699us 
std.Thread.Pool: Fixed 100      157.912ms      1.579ms ± 64.376us     (1.476ms ... 1.771ms)        1.604ms    1.771ms    1.771ms   
std.Thread.Pool: Smp   100      161.693ms      1.616ms ± 64.229us     (1.516ms ... 1.832ms)        1.65ms     1.832ms    1.832ms
```
Thread usage, count of jobs picked up per thread.

LibZ:
| ThreadId | Count of jobs|
|----------|------------- |
| 38546            | 2046     |
| 38547            | 1        |
| **Total Result** | **2047** |

std.Thread.Pool:
| ThreadId | Count of jobs|
|----------|------------- |
| 38863            | 141      |
| 38864            | 257      |
| 38865            | 59       |
| 38866            | 202      |
| 38867            | 43       |
| 38868            | 199      |
| 38869            | 76       |
| 38870            | 105      |
| 38871            | 26       |
| 38872            | 54       |
| 38873            | 214      |
| 38874            | 88       |
| 38875            | 32       |
| 38876            | 219      |
| 38877            | 155      |
| 38878            | 145      |
| 38879            | 32       |
| **Total Result** | **2047** |

See the code [here](src/benchmarks/basic_ordered/main.zig)
