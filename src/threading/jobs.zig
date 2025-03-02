const std = @import("std");
const debug = std.debug;
const assert = @import("assert");

const Atomic = std.atomic.Value;
const Thread = std.Thread;
const BoundedArray = std.BoundedArray;
const BoundedArrayAligned = std.BoundedArrayAligned;
const FixedDeque = @import("fixed_deque.zig").FixedDeque;

pub const JobHandle = packed struct(u16) {
    index: u11,
    thread: u5,
};

pub const JobQueueConfig = struct {
    // For each thread a seperate queue will be created, this config dictates the size of that queue.
    max_jobs_per_thread: u16,

    // Dictates max number of threads
    max_threads: u16 = 32,

    // Amount of time to wait before trying to fetch a new job from the queue, If the queue is empty,
    // lowering this setting will result in high CPU and thus battery usage.
    idle_sleep_ns: u16 = 50,
};

pub fn JobQueue(comptime config: JobQueueConfig) type {
    // Should atleast have 2 threads to be able to spawn
    comptime debug.assert(config.max_threads >= 2);

    // For optimization we only allow a count of a multiple of 2
    comptime debug.assert(assert.isPowerOf2(config.max_jobs_per_thread));

    const ExecData = [76]u8;
    const ExecFn = *const fn (*ExecData) void;

    const Job = struct {
        const Self = @This();

        // The function to call
        exec: ExecFn,

        // Parent job that spawned this job, can be executed in parallel of this job
        parent: ?JobHandle,

        // Jobs that need to be awaited before this job is completed, can be executed in parallel of this job
        job_count: u16,

        // Child jobs, these need to be executed after this job has run
        child_count: u16,
        child_jobs: [16]JobHandle,

        // Data passed to the function
        data: ExecData,

        pub fn init(comptime T: type, job: *const T) Self {
            var self: Self = .{
                .exec = undefined,
                .data = undefined,
                .parent = undefined,
                .job_count = 1,
                .child_count = 0,
                .child_jobs = .{undefined} ** 16,
            };

            const bytes = std.mem.asBytes(job);
            @memcpy(self.data[0..bytes.len], bytes);

            const exec: *const fn (*T) void = &@field(T, "exec");

            self.exec = @as(ExecFn, @ptrCast(exec));

            return self;
        }

        pub fn isCompleted(self: *const Self) bool {
            return @atomicLoad(u16, &self.job_count, .monotonic) == 0;
        }
    };

    return struct {
        pub const max_jobs_per_thread = config.max_jobs_per_thread;
        pub const sleep_time_ns = config.idle_sleep_ns;
        const max_thread_count = config.max_threads;
        const max_thread_queue_count = max_thread_count + 1;

        const Self = @This();
        const Deque = FixedDeque(*Job, max_jobs_per_thread);
        const Jobs = BoundedArrayAligned(Job, 128, max_jobs_per_thread);

        const jobs_per_thread_mask = max_jobs_per_thread - 1;

        // Each thread has it's own queue, because we allow for job stealing from other threads the queue
        // itself is not thread local
        threadlocal var thread_queue_index: u32 = 0;

        /// Allocator used in init and deinit functions for allocating job buffers and queues
        allocator: std.mem.Allocator,

        // Each thread has it's own job buffer containing max_jobs_per_thread jobs.
        // Jobs are allocated from this buffer and deallocated to this buffer. is implemented as a ringbuffer.
        // JobHandle points to an index of this storage.
        jobs: []Jobs,

        // All the queues, one per spawned thread plus one for the main thread
        queues: []Deque,

        // All the threads, should be at most @min(getCpuCount() - 1, max_threads)
        threads: []Thread,

        // Main thread ID, stored so we can assert start is called from the main thread.
        main_thread: Atomic(u64) = .{ .raw = 0 },

        // While true, the threads will keep trying to pick jobs from the queue, if set to false only
        // The picked up jobs will be completed
        is_running: Atomic(bool) = .{ .raw = false },

        /// Needs to be called before any other function
        pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Self {
            const thread_count = @min(max_thread_count, (Thread.getCpuCount() catch 2) - 1);
            const thread_queue_count = thread_count + 1;

            const self: Self = .{
                .allocator = allocator,
                .jobs = try allocator.alloc(Jobs, thread_queue_count),
                .queues = try allocator.alloc(Deque, thread_queue_count),
                .threads = try allocator.alloc(Thread, thread_count),
            };

            for (self.queues, self.jobs) |*queue, *jobs| {
                queue.* = Deque.init();
                jobs.* = .{};
            }

            return self;
        }

        /// Needs to be called as last to cleanup memory
        pub fn deinit(self: *Self) void {
            const is_running = self.is_running.load(.monotonic);
            debug.assert(is_running == false);

            self.allocator.free(self.jobs);
            self.allocator.free(self.queues);
            self.allocator.free(self.threads);
        }

        /// Starts the threads, from this call onwards the threads will try to pickup jobs from their
        /// queues.
        pub fn start(self: *Self) !void {
            const current_thread = Thread.getCurrentId();
            const prev_thread = self.main_thread.swap(current_thread, .monotonic);
            debug.assert(prev_thread == 0);

            const was_running = self.is_running.swap(true, .monotonic);
            debug.assert(was_running == false);

            for (self.threads, 0..) |*thread, i| {
                thread.* = try Thread.spawn(.{}, run, .{ self, @as(u32, @intCast(i + 1)) });
            }
        }

        /// Stops the threads from listening to the queues, they will not pickup any new jobs from the
        /// queue, meaning that not all jobs will be finished.
        pub fn stop(self: *Self) void {
            const was_running = self.is_running.swap(false, .monotonic);
            debug.assert(was_running);
        }

        /// Joins all threads again, you can call this before stop but than a Job on another thread
        /// will need to call stop, otherwise this will wait indefinatley
        pub fn join(self: *Self) void {
            debug.assert(self.isMainThread());

            for (self.threads) |thread| {
                thread.join();
            }
        }

        /// Allocates a Job, needs to be called in order to get a valid handle that can than be scheduled
        pub fn allocate(self: *Self, job: anytype) JobHandle {
            const JobType = @TypeOf(job);

            var jobs = self.getThreadJobBuffer();
            defer jobs.len += 1;

            const job_index: u32 = @intCast(jobs.len & jobs_per_thread_mask);

            jobs.buffer[job_index] = Job.init(JobType, &job);

            return .{
                .index = @intCast(job_index),
                .thread = @intCast(thread_queue_index),
            };
        }

        /// Puts the job in a queue so it can be picked up by a thread
        pub fn schedule(self: *Self, handle: JobHandle) void {
            const queue = self.getThreadQueue();
            const job = self.getJobFromBuffer(handle);

            queue.push(job);
        }

        /// awaits the job to finish and while not finished yet will work on other jobs.
        pub fn wait(self: *Self, handle: JobHandle) void {
            const job = self.getJobFromBuffer(handle);
            while (!job.isCompleted()) {
                self.execNextJob();
            }
        }

        /// awaits the job to finish and while not finished yet will work on other jobs. This will
        /// return the result of the job. A simpler and slightly faster way of calling 'wait' and then 'result'.
        pub fn waitResult(self: *Self, T: type, handle: JobHandle) T {
            const job = self.getJobFromBuffer(handle);
            while (!job.isCompleted()) {
                self.execNextJob();
            }
            return std.mem.bytesToValue(T, &job.data);
        }

        /// returns the result of a completed job. asserts the job has actually been completed.
        pub fn result(self: *Self, T: type, handle: JobHandle) T {
            debug.assert(self.isCompleted(handle));
            const job = self.getJobFromBuffer(handle);
            return std.mem.bytesToValue(T, &job.data);
        }

        /// adds a job that will run after the main job has completed, multiple jobs can be added, they
        /// will be executed after the main job in same order of calling this function.
        pub fn continueWith(self: *Self, handle: JobHandle, continuation_handle: JobHandle) void {
            const parent = self.getJobFromBuffer(handle);
            const prev = @atomicRmw(u16, &parent.child_count, .Add, 1, .monotonic);
            parent.child_jobs[prev] = continuation_handle;
            debug.assert(prev < 16);
        }

        /// allows to await multiple jobs through a single job. once the finish_handle is awaited, all other jobs are
        /// guaranteed to be finished as well, though it does not enforce execution order. the 'finish job' function could be executed
        /// as first but will not be set to completed until all related jobs have finished executing.
        pub fn finishWith(self: *Self, handle: JobHandle, finish_handle: JobHandle) void {
            const child = self.getJobFromBuffer(handle);
            const parent = self.getJobFromBuffer(finish_handle);
            _ = @atomicRmw(u16, &parent.job_count, .Add, 1, .monotonic);

            child.parent = finish_handle;
        }

        /// returns of the current thread is the main thread
        pub fn isMainThread(self: *Self) bool {
            const current_thread = Thread.getCurrentId();
            const main_thread = self.main_thread.load(.monotonic);
            debug.assert(main_thread != 0);

            return main_thread == current_thread;
        }

        /// returns whether the passed job has been completed
        pub fn isCompleted(self: *const Self, handle: JobHandle) bool {
            const job = self.getJobFromBufferConst(handle);
            return job.isCompleted();
        }

        fn run(self: *Self, queue_index: u32) void {
            debug.assert(thread_queue_index == 0);

            thread_queue_index = queue_index;

            while (self.is_running.load(.monotonic)) {
                self.execNextJob();
            }
        }

        fn execNextJob(self: *Self) void {
            if (self.getJob()) |job| {
                job.exec(&job.data);
                self.finishJob(job);
            }
        }

        fn getJob(self: *Self) ?*Job {
            var queue = self.getThreadQueue();
            if (queue.pop()) |job| {
                return job;
            }

            for (1..self.queues.len) |i| {
                const index = (i + thread_queue_index) % self.queues.len;
                debug.assert(thread_queue_index != index);

                if (self.queues[index].steal()) |job| {
                    return job;
                }
            }

            Thread.sleep(config.idle_sleep_ns);

            return null;
        }

        fn finishJob(self: *Self, job: *Job) void {
            const prev = @atomicRmw(u16, &job.job_count, .Sub, 1, .monotonic);
            if (prev == 1) {
                if (job.parent) |parent| {
                    const parent_job = self.getJobFromBuffer(parent);
                    self.finishJob(parent_job);
                }

                for (0..job.child_count) |i| {
                    const child_job = self.getJobFromBuffer(job.child_jobs[i]);
                    const queue = self.getThreadQueue();
                    queue.push(child_job);
                }
            }
        }

        inline fn getThreadQueue(self: *Self) *Deque {
            return &self.queues[thread_queue_index];
        }

        inline fn getThreadJobBuffer(self: *Self) *Jobs {
            return &self.jobs[thread_queue_index];
        }

        inline fn getJobFromBuffer(self: *Self, handle: JobHandle) *Job {
            return &self.jobs[handle.thread].buffer[handle.index];
        }

        inline fn getJobFromBufferConst(self: *const Self, handle: JobHandle) *const Job {
            return &self.jobs[handle.thread].buffer[handle.index];
        }
    };
}

test "JobQueue: can init" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const config: JobQueueConfig = .{
        .max_jobs_per_thread = 4,
    };
    var jobs = try JobQueue(config).init(allocator);
    defer jobs.deinit();

    try testing.expectEqual(0, jobs.main_thread.raw);
    try testing.expectEqual(false, jobs.is_running.raw);
}

test "JobQueue: can start and stop" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const config: JobQueueConfig = .{
        .max_jobs_per_thread = 4,
    };

    var jobs = try JobQueue(config).init(allocator);
    defer jobs.deinit();

    try jobs.start();
    try testing.expectEqual(true, jobs.is_running.raw);

    jobs.stop();
    try testing.expectEqual(false, jobs.is_running.raw);
}

test "JobQueue: can join before stop" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const config: JobQueueConfig = .{
        .max_jobs_per_thread = 4,
    };

    var jobs = try JobQueue(config).init(allocator);
    defer jobs.deinit();

    const StopJob = struct {
        jobs: *@TypeOf(jobs),
        pub fn exec(self: *@This()) void {
            self.jobs.stop();
        }
    };

    try jobs.start();
    try testing.expectEqual(true, jobs.is_running.raw);

    const stop_job = jobs.allocate(StopJob{ .jobs = &jobs });
    jobs.schedule(stop_job);
    jobs.join();

    try testing.expectEqual(false, jobs.is_running.raw);
}

test "JobQueue: can join after stop" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const config: JobQueueConfig = .{
        .max_jobs_per_thread = 4,
    };

    var jobs = try JobQueue(config).init(allocator);
    defer jobs.deinit();

    try jobs.start();
    try testing.expectEqual(true, jobs.is_running.raw);

    jobs.stop();
    try testing.expectEqual(false, jobs.is_running.raw);
    jobs.join();
}

test "JobQueue: can allocate jobs" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const config: JobQueueConfig = .{
        .max_jobs_per_thread = 4,
    };

    const Job = struct {
        pub fn exec(_: *@This()) void {}
    };

    var jobs = try JobQueue(config).init(allocator);
    defer jobs.deinit();

    // try jobs.start();
    // defer jobs.join();
    // defer jobs.stop();

    const job = jobs.allocate(Job{});
    try testing.expectEqual(0, job.index);

    const job1 = jobs.allocate(Job{});
    try testing.expectEqual(1, job1.index);
}

test "JobQueue: allocating more jobs than config.max_jobs_per_thread will overwrite previously allocated job" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const config: JobQueueConfig = .{
        .max_jobs_per_thread = 4,
    };

    const Job = struct {
        pub fn exec(_: *@This()) void {}
    };

    var jobs = try JobQueue(config).init(allocator);
    defer jobs.deinit();

    try jobs.start();
    defer jobs.join();
    defer jobs.stop();

    const job = jobs.allocate(Job{});
    try testing.expectEqual(0, job.index);

    const job1 = jobs.allocate(Job{});
    try testing.expectEqual(1, job1.index);

    const job2 = jobs.allocate(Job{});
    try testing.expectEqual(2, job2.index);

    const job3 = jobs.allocate(Job{});
    try testing.expectEqual(3, job3.index);

    // This will overwrite job at index 0 as it's a ringbuffer.
    const job4 = jobs.allocate(Job{});
    try testing.expectEqual(0, job4.index);
}

test "JobQueue: can schedule jobs before start on main thread" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const config: JobQueueConfig = .{
        .max_jobs_per_thread = 4,
    };

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

    const handle1 = jobs.allocate(Job{});
    jobs.schedule(handle1);

    try testing.expectEqual(2, jobs.getThreadQueue().len());

    try jobs.start();

    defer jobs.join();
    defer jobs.stop();
}

test "JobQueue: scheduled jobs can be awaited" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const config: JobQueueConfig = .{
        .max_jobs_per_thread = 4,
    };

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

    jobs.wait(handle);

    try testing.expectEqual(0, jobs.getThreadQueue().len());

    defer jobs.join();
    defer jobs.stop();
}

test "JobQueue: result of job is available after 'wait'" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const config: JobQueueConfig = .{
        .max_jobs_per_thread = 4,
    };

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

    jobs.wait(handle);

    try testing.expectEqual(0, jobs.getThreadQueue().len());

    const result = jobs.result(Job, handle);

    try testing.expectEqual(1, result.foo);

    defer jobs.join();
    defer jobs.stop();
}

test "JobQueue: result of job can be returned directly by waitResult" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const config: JobQueueConfig = .{
        .max_jobs_per_thread = 4,
    };

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

    const result = jobs.waitResult(Job, handle);

    try testing.expectEqual(1, result.foo);

    defer jobs.join();
    defer jobs.stop();
}

test "JobQueue: jobs are spread out over all threads" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const config: JobQueueConfig = .{
        .max_jobs_per_thread = 4,
    };

    const Job = struct {
        thread: Thread.Id = 0,
        pub fn exec(self: *@This()) void {
            self.thread = Thread.getCurrentId();
            // simulate some work to be done
            Thread.sleep(50);
        }
    };

    var jobs = try JobQueue(config).init(allocator);
    defer jobs.deinit();

    const tasks = try allocator.alloc(JobHandle, 4);
    defer allocator.free(tasks);
    const results = try allocator.alloc(Job, 4);
    defer allocator.free(results);

    for (tasks) |*task| {
        task.* = jobs.allocate(Job{});
        jobs.schedule(task.*);
    }

    try jobs.start();
    defer jobs.join();
    defer jobs.stop();

    for (results, tasks) |*result, task| {
        result.* = jobs.waitResult(Job, task);
    }

    try testing.expectEqual(0, jobs.getThreadQueue().len());
}

test "JobQueue: finishWith job can be used to build up tree structure and awaited in one go" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const config: JobQueueConfig = .{
        .max_jobs_per_thread = 256,
    };
    var jobs = try JobQueue(config).init(allocator);
    defer jobs.deinit();

    try jobs.start();
    defer jobs.join();
    defer jobs.stop();

    const Root = struct {
        pub fn exec(_: *@This()) void {}
    };

    const Child = struct {
        pub fn exec(_: *@This()) void {}
    };

    const root = jobs.allocate(Root{});
    // This is a very efficient way as we can already run child jobs while we are scheduling them.
    for (0..255) |_| {
        const child = jobs.allocate(Child{});
        jobs.finishWith(child, root);
        jobs.schedule(child);
    }
    jobs.schedule(root);
    jobs.wait(root);

    try testing.expectEqual(true, jobs.isCompleted(root));
}

test "JobQueue: continueWith jobs can be added and are run in order after completion main job" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const config: JobQueueConfig = .{
        .max_jobs_per_thread = 4,
    };
    var jobs = try JobQueue(config).init(allocator);
    defer jobs.deinit();

    var data: [3]u8 = undefined;
    var index: usize = 0;

    const Parent = struct {
        result: []u8,
        index: *usize,

        pub fn exec(self: *@This()) void {
            self.result[self.index.*] = 1;
            self.index.* += 1;
        }
    };

    const Child = struct {
        result: []u8,
        index: *usize,

        pub fn exec(self: *@This()) void {
            self.result[self.index.*] = 2;
            self.index.* += 1;
        }
    };

    const Child1 = struct {
        result: []u8,
        index: *usize,

        pub fn exec(self: *@This()) void {
            self.result[self.index.*] = 3;
            // self.index.* += 1;
        }
    };

    const parent_job: Parent = .{
        .result = &data,
        .index = &index,
    };

    const parent = jobs.allocate(parent_job);

    const child_job: Child = .{
        .result = &data,
        .index = &index,
    };
    const child = jobs.allocate(child_job);

    const child1_job: Child1 = .{
        .result = &data,
        .index = &index,
    };
    const child1 = jobs.allocate(child1_job);

    jobs.continueWith(parent, child);
    jobs.continueWith(child, child1);

    try jobs.start();
    defer jobs.join();
    defer jobs.stop();

    jobs.schedule(parent);

    const result = jobs.waitResult(Parent, parent);
    const expected: [3]u8 = .{ 1, 2, 3 };
    try testing.expectEqualSlices(u8, &expected, result.result);
}

test "Readme simple example" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // defines the config for the jobs, available configs are:
    // - max_jobs_per_thread
    // - max_threads
    // - idle_sleep_ns
    const config: JobQueueConfig = .{
        .max_jobs_per_thread = 4,
    };
    // This preallocates the jobs per threads and the queues per thread
    var jobs = try JobQueue(config).init(allocator);
    // don't forget to cleanup
    defer jobs.deinit();

    // Let's define a job, the job struct size can be at most 76 bytes, if more data is needed it
    // might be best to use a pointer to store to some allocated memory.
    const Job = struct {
        // this function is required. you can discard the parameter if not needed by using the _ syntax.
        pub fn exec(_: *@This()) void {
            std.debug.print("hello", .{});
        }
    };

    // Let's allocate our job, this is very fast as it uses a circular buffer pool to allocate jobs from
    // each thread has it's own pool so allocating can be done lock free. Keep in mind that the 'max_jobs_per_thread' count
    // is allocated per thread, this will result in a memory footprint of 128(total job size) * max_jobs_per_thread * thread count
    const handle = jobs.allocate(Job{});

    // Now we schedule the job. as soon as jobs.start is called it will be picked up by one of the threads.
    jobs.schedule(handle);

    // From this point onwards, any jobs scheduled will be picked up by one of the spawned threads, you can pre-schedule
    // some threads and then call start but you can also call start first. Is required to be called from the main thread.
    try jobs.start();

    // here we make sure the job is completed until we continue, while we are waiting this call might
    // pickup other jobs so we do something useful while waiting.
    jobs.wait(handle);

    // now we stop the threads from picking up other jobs. after this call we can join our threads.
    jobs.stop();

    // Here we call thread.join on all our threads, if stop is not called it will block the calling thread indefinitely.
    // you can always call join though and call stop from another thread. a nicer way to do this might be using something like
    // defer jobs.join();
    // defer jobs.stop();
    jobs.join();
}

test "Readme continueWith example" {
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
}

test "Readme finishWith" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const config: JobQueueConfig = .{
        .max_jobs_per_thread = 4,
    };
    var jobs = try JobQueue(config).init(allocator);
    defer jobs.deinit();

    const buffer: [256]u8 = undefined;

    const RootJob = struct {
        slice: []const u8,
        pub fn exec(self: *@This()) void {}
    };

    const UpdateBufferJob = struct {
        value: u8,
        slice: []const u8,
        pub fn exec(self: *@This()) void {
            @memset(slice, value);
        }
    };

    // We are still responsible of scheduling all the child jobs.
    // This is a very efficient way of scheduling them, this because we now can
    // already work on jobs while scheduling them on the main thread.
    for (0..255) |_| {
        const child = jobs.allocate(Child{});
        // Here we basically say, if root is finished, so will this job.
        jobs.finishWith(child, root);
        // Let's schedule it so our worker threads can already pick it up while
        // we are continue scheduling on the main thread.
        jobs.schedule(child);
    }
    jobs.schedule(root);
    jobs.wait(root);
}
