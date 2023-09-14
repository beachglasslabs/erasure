const chunk = @import("chunk.zig");
const erasure = @import("../erasure.zig");

const pipelines = @import("../pipelines.zig");
const digestBytesToString = pipelines.digestBytesToString;

const PipelineInitValues = @import("PipelineInitValues.zig");

const ServerInfo = @import("ServerInfo.zig");
const SensitiveBytes = @import("../SensitiveBytes.zig");
const SharedQueue = @import("../shared_queue.zig").SharedQueue;

const std = @import("std");
const assert = std.debug.assert;
const Sha256 = std.crypto.hash.sha2.Sha256;

const util = @import("../util.zig");

pub const Ctx = struct {
    ptr: *anyopaque,
    actionFn: *const fn (ptr: *anyopaque, state: Action) void,
    data: Data,

    pub const Data = struct {
        chunk_names: []const [Sha256.digest_length]u8,
    };

    pub inline fn init(data: Data, ctx_ptr: anytype) Ctx {
        const Ptr = @TypeOf(ctx_ptr);
        const gen = struct {
            fn actionFn(erased_ptr: *anyopaque, action_data: Ctx.Action) void {
                const ptr: Ptr = @ptrCast(@alignCast(erased_ptr));
                switch (action_data) {
                    .update => |percentage| ptr.update(percentage),
                    .close => ptr.close(),
                }
            }
        };
        return .{
            .ptr = ctx_ptr,
            .actionFn = gen.actionFn,
            .data = data,
        };
    }

    pub inline fn update(self: Ctx, percentage: u8) void {
        return self.action(.{ .update = percentage });
    }

    pub inline fn close(self: Ctx) void {
        return self.action(.{ .close = {} });
    }

    inline fn action(self: Ctx, data: Action) void {
        return self.actionFn(self.ptr, data);
    }

    pub const Action = union(enum) {
        /// percentage of progress
        update: u8,
        close,
    };
};

pub fn PipeLine(comptime W: type) type {
    return struct {
        allocator: std.mem.Allocator,
        requests_buf: []std.http.Client.Request,
        server_info: ServerInfo,
        gc_prealloc: ?ServerInfo.GoogleCloud.PreAllocated,

        must_stop: std.atomic.Atomic(bool),
        queue_mtx: std.Thread.Mutex,
        queue: SharedQueue(Ctx),

        chunk_headers_buf_mtx: std.Thread.Mutex,
        chunk_headers_buf: std.ArrayListUnmanaged(chunk.Header),
        chunk_buffer: []u8,

        random: std.rand.Random,
        ec: ErasureCoder,
        thread: std.Thread,
        const Self = @This();

        const ErasureCoder = erasure.Coder(W);

        // TODO: should this use a more strict memory order?
        const must_stop_store_mo: std.builtin.AtomicOrder = .Monotonic;
        const must_stop_load_mo: std.builtin.AtomicOrder = .Monotonic;

        pub fn init(
            /// contents will be entirely oerwritten
            self: *Self,
            /// should be a thread-safe allocator
            allocator: std.mem.Allocator,
            /// should be thread-safe Pseudo-RNG
            random: std.rand.Random,
            values: PipelineInitValues,
        ) (std.mem.Allocator.Error || ErasureCoder.InitError || std.Thread.SpawnError)!void {
            assert(values.chunk_buffer != 0);
            assert(values.queue_capacity != 0);

            self.* = .{
                .allocator = allocator,
                .requests_buf = &.{},
                .server_info = values.server_info,
                .gc_prealloc = null,

                .must_stop = std.atomic.Atomic(bool).init(false),
                .queue_mtx = .{},
                .queue = undefined,

                .chunk_headers_buf_mtx = .{},
                .chunk_headers_buf = .{},
                .chunk_buffer = &.{},

                .random = random,
                .ec = undefined,
                .thread = undefined,
            };

            self.requests_buf = try self.allocator.alloc(std.http.Client.Request, values.server_info.bucketCount());
            errdefer self.allocator.free(self.requests_buf);

            if (values.server_info.google_cloud) |gc| {
                self.gc_prealloc = try gc.preAllocated(self.allocator);
            }
            errdefer if (self.gc_prealloc) |pre_alloc| pre_alloc.deinit(self.allocator);

            self.queue = try SharedQueue(Ctx).initCapacity(&self.queue_mtx, self.allocator, values.queue_capacity);
            errdefer self.queue.deinit(self.allocator);

            self.chunk_buffer = try allocator.alloc(u8, values.chunk_buffer);
            errdefer allocator.free(self.chunk_buffer);

            self.ec = try ErasureCoder.init(self.allocator, @intCast(values.server_info.bucketCount()), values.server_info.shard_size);
            errdefer self.ec.deinit(self.allocator);

            self.thread = try std.Thread.spawn(.{ .allocator = self.allocator }, downloadPipeLineThread, .{self});
        }

        pub fn deinit(
            self: *Self,
            remaining_queue_fate: enum {
                finish_remaining_uploads,
                cancel_remaining_uploads,
            },
        ) void {
            self.must_stop.store(true, must_stop_store_mo);
            switch (remaining_queue_fate) {
                .finish_remaining_uploads => {},
                .cancel_remaining_uploads => self.queue.clearItems(),
            }
            self.thread.join();
            self.queue.deinit(self.allocator);

            self.chunk_headers_buf.deinit(self.allocator);
            self.allocator.free(self.chunk_buffer);

            self.ec.deinit(self.allocator);
            self.allocator.free(self.requests_buf);
            if (self.gc_prealloc) |pre_alloc| pre_alloc.deinit(self.allocator);
        }

        pub fn downloadFile(
            self: *Self,
            digests: []const [Sha256.digest_length]u8,
            ctx_ptr: anytype,
        ) !void {
            {
                self.chunk_headers_buf_mtx.lock();
                defer self.chunk_headers_buf_mtx.unlock();
                try self.chunk_headers_buf.ensureTotalCapacity(self.allocator, digests.len);
            }
            const data = Ctx.Data{
                .chunk_names = digests,
            };
            _ = try self.queue.pushValue(self.allocator, Ctx.init(data, ctx_ptr));
        }

        fn downloadPipeLineThread(dpp: *Self) void {
            var client = std.http.Client{ .allocator = dpp.allocator };
            defer client.deinit();

            while (true) {
                const down_ctx: Ctx = dpp.queue.popValue() orelse {
                    if (dpp.must_stop.load(must_stop_load_mo)) break;
                    std.atomic.spinLoopHint();
                    continue;
                };
                defer down_ctx.close();

                const excluded_index_set = erasure.sampleIndexSet(
                    dpp.random,
                    dpp.ec.shardCount(),
                    dpp.ec.shardCount() - dpp.ec.shardsRequired(),
                );
                var current_index: u8 = 0;

                var maybe_file: ?std.fs.File = null;
                defer if (maybe_file) |file| file.close();

                for (down_ctx.data.chunk_names) |chunk_name| {
                    var requests = util.BoundedBufferArray(std.http.Client.Request){ .buffer = dpp.requests_buf };
                    defer for (requests.slice()) |*req| req.deinit();

                    if (dpp.server_info.google_cloud) |gc| {
                        const gc_prealloc = dpp.gc_prealloc.?;

                        var iter = gc_prealloc.bucketObjectUriIterator(gc, &chunk_name);

                        while (iter.next()) |uri_str| : (current_index += 1) {
                            if (excluded_index_set.isSet(current_index)) continue;

                            const uri = std.Uri.parse(uri_str) catch unreachable;
                            const req = client.request(.GET, uri, gc_prealloc.headers, .{}) catch |err| switch (err) {
                                error.OutOfMemory => @panic("TODO: actually handle this scenario in some way that isn't just panicking on this thread"),
                                inline else => |e| @panic("Decide how to handle " ++ @errorName(e)),
                            };
                            requests.appendAssumingCapacity(req);
                        }
                    }

                    // NOTE: this should be safe from any race condition, because
                    // the only other place where this field is modified is in
                    // `downloadFile`, where it calls `ensureTotalCapacity`, which
                    // should not modify the `items.len` field at all, which is
                    // all this function does.
                    dpp.chunk_headers_buf.clearRetainingCapacity();

                    for (requests.slice()) |*req| {
                        req.start() catch |err| @panic(switch (err) {
                            inline else => |e| "Decide how to handle " ++ @errorName(e),
                        });
                        req.finish() catch |err| @panic(switch (err) {
                            inline else => |e| "Decide how to handle " ++ @errorName(e),
                        });
                        req.wait() catch |err| switch (err) {
                            error.OutOfMemory => @panic("TODO: actually handle this scenario in some way that isn't just panicking on this thread"),
                            inline else => |e| @panic("Decide how to handle " ++ @errorName(e)),
                        };

                        const header = chunk.readHeader(req.reader()) catch |err| switch (err) {
                            inline else => |e| @panic("Decide how to handle " ++ @errorName(e)),
                        };

                        dpp.chunk_headers_buf_mtx.lock();
                        defer dpp.chunk_headers_buf_mtx.unlock();
                        dpp.chunk_headers_buf.appendAssumeCapacity(header);
                    }

                    const ReadersCtx = struct {
                        requests: []std.http.Client.Request,
                        down_ctx: Ctx,

                        const ReaderCtx = struct {
                            inner: Inner,
                            down_ctx: Ctx,

                            const Inner = std.http.Client.Request.Reader;
                            const Error = Inner.Error;
                            fn read(self: @This(), buf: []u8) Error!usize {
                                const result = try self.inner.read(buf);
                                return result;
                            }
                        };
                        pub inline fn getReader(ctx: @This(), reader_idx: u7) std.io.Reader(ReaderCtx, ReaderCtx.Error, ReaderCtx.read) {
                            return .{ .context = .{
                                .inner = ctx.requests[reader_idx].reader(),
                                .down_ctx = ctx.down_ctx,
                            } };
                        }
                    };
                    const readers_ctx = ReadersCtx{
                        .requests = requests.slice(),
                        .down_ctx = down_ctx,
                    };

                    const file = maybe_file orelse blk: {
                        const file = std.fs.cwd().createFile("decoded", .{}) catch |err| switch (err) {
                            inline else => |e| @panic("Decide how to handle " ++ @errorName(e)),
                        };
                        maybe_file = file;
                        break :blk file;
                    };

                    var buffered = std.io.bufferedWriter(file.writer());
                    _ = dpp.ec.decodeCtx(excluded_index_set, buffered.writer(), readers_ctx) catch |err| switch (err) {
                        inline else => |e| @panic("Decide how to handle " ++ @errorName(e)),
                    };
                    buffered.flush() catch |err| switch (err) {
                        inline else => |e| @panic("Decide how to handle " ++ @errorName(e)),
                    };
                }
            }
        }
    };
}
