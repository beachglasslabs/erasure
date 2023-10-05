const chunk = @import("chunk.zig");
const builtin = @import("builtin");
const eraser = @import("../pipelines.zig");
const erasure = eraser.erasure;
const ServerInfo = @import("ServerInfo.zig");
const ManagedQueue = @import("../managed_queue.zig").ManagedQueue;
const StoredFile = eraser.StoredFile;

const std = @import("std");
const assert = std.debug.assert;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

const util = @import("../util.zig");

pub inline fn pipeLine(
    comptime W: type,
    comptime Src: type,
    init_values: PipeLine(W, Src).InitValues,
) PipeLine(W, Src).InitError!PipeLine(W, Src) {
    return PipeLine(W, Src).init(init_values);
}

pub fn PipeLine(
    comptime W: type,
    /// `Src.Reader`         = `std.io.Reader(...)`
    /// `Src.SeekableStream` = `std.io.SeekableStream(...)`
    /// `Src.reader`         = `fn (Src) Src.Reader`
    /// `Src.seekableStream` = `fn (Src) Src.SeekableStream`
    comptime Src: type,
) type {
    const SrcNs = verifySrcType(Src) catch |err| @compileError(@errorName(err));
    return struct {
        //! All fields in this container are private and not to be modified directly unless
        //! explicitly stated otherwise in the field's doc comment.

        allocator: std.mem.Allocator,
        server_info: ServerInfo,
        gc_prealloc: ?ServerInfo.GoogleCloud.PreAllocated,

        must_stop: std.atomic.Atomic(bool),
        queue_mtx: std.Thread.Mutex,
        queue_pop_re: std.Thread.ResetEvent,
        queue: ManagedQueue(QueueItem),

        requests_buf: []std.http.Client.Request,
        /// decrypted_chunk_buffer = &chunk_buffer[0]
        /// encrypted_chunk_buffer = &chunk_buffer[1]
        chunk_buffers: *[2][header_plus_chunk_max_size]u8,

        random: std.rand.Random,
        ec: ErasureCoder,
        thread: ?std.Thread,
        const Self = @This();

        const header_plus_chunk_max_size = chunk.size + chunk.Header.size;

        const ErasureCoder = erasure.Coder(W);
        const QueueItem = struct {
            ctx: Ctx,
            src: Src,
            full_size: u64,
        };

        // TODO: should this use a more strict memory order?
        const must_stop_store_mo: std.builtin.AtomicOrder = .Monotonic;
        const must_stop_load_mo: std.builtin.AtomicOrder = .Monotonic;

        pub const InitValues = struct {
            /// should be a thread-safe allocator
            allocator: std.mem.Allocator,
            /// should be thread-safe Pseudo-RNG
            random: std.rand.Random,
            /// initial capacity of the queue
            queue_capacity: usize,
            /// server provider configuration
            server_info: ServerInfo,
        };

        pub const InitError = std.mem.Allocator.Error || ErasureCoder.InitError || std.Thread.SpawnError;
        pub fn init(
            values: InitValues,
        ) InitError!Self {
            assert(values.queue_capacity != 0);
            var self: Self = .{
                .allocator = values.allocator,
                .server_info = values.server_info,
                .gc_prealloc = null,

                .must_stop = std.atomic.Atomic(bool).init(false),
                .queue_mtx = .{},
                .queue_pop_re = .{},
                .queue = undefined,

                .requests_buf = &.{},
                .chunk_buffers = undefined,

                .random = values.random,
                .ec = undefined,
                .thread = null,
            };

            if (values.server_info.google_cloud) |gc| {
                self.gc_prealloc = try gc.preAllocated(self.allocator);
            }
            errdefer if (self.gc_prealloc) |pre_alloc| pre_alloc.deinit(self.allocator);

            self.queue = try ManagedQueue(QueueItem).initCapacity(self.allocator, values.queue_capacity);
            errdefer self.queue.deinit(self.allocator);

            self.requests_buf = try self.allocator.alloc(std.http.Client.Request, values.server_info.bucketCount());
            errdefer self.allocator.free(self.requests_buf);

            self.chunk_buffers = try self.allocator.create([2][header_plus_chunk_max_size]u8);
            errdefer self.allocator.destroy(self.chunk_buffers);

            self.ec = try ErasureCoder.init(self.allocator, .{
                .shard_count = @intCast(values.server_info.bucketCount()),
                .shards_required = values.server_info.shards_required,
            });
            errdefer self.ec.deinit(self.allocator);

            return self;
        }

        pub inline fn start(self: *Self) !void {
            assert(self.thread == null);
            self.thread = try std.Thread.spawn(.{ .allocator = self.allocator }, uploadPipeLineThread, .{self});
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
                .cancel_remaining_uploads => {
                    self.queue_mtx.lock();
                    defer self.queue_mtx.unlock();
                    self.queue.clearItems();
                },
            }

            self.queue_pop_re.set();
            if (self.thread) |thread| thread.join();
            self.queue.deinit(self.allocator);

            self.allocator.destroy(self.chunk_buffers);
            self.allocator.free(self.requests_buf);

            self.ec.deinit(self.allocator);
            if (self.gc_prealloc) |pre_alloc| pre_alloc.deinit(self.allocator);
        }

        const UploadParams = struct {
            /// The content source. Must be copy-able by value - if it is a pointer
            /// or handle of some sort, it must outlive the pipeline, or it must only
            /// become invalid after being passed to `ctx_ptr.close`.
            /// Must provide `src.seekableStream()` and `src.reader()`.
            src: Src,
            /// Pre-calculated size of the contents; if `null`,
            /// the size will be determined during this function call.
            full_size: ?u64 = null,
        };
        pub inline fn uploadFile(
            self: *Self,
            ctx_ptr: anytype,
            params: UploadParams,
        ) (std.mem.Allocator.Error || SrcNs.SeekableStream.GetSeekPosError)!void {
            const src = params.src;
            const ctx = Ctx.init(ctx_ptr);

            const full_size: u64 = size: {
                const reported_full_size = params.full_size orelse {
                    break :size try src.seekableStream().getEndPos();
                };
                if (comptime @import("builtin").mode == .Debug) debug_check: {
                    const real_full_size = try src.seekableStream().getEndPos();
                    if (real_full_size == reported_full_size) break :debug_check;
                    const msg = util.boundedFmt(
                        "Given file size '{d}' differs from file size '{d}' obtained from stat",
                        .{ reported_full_size, real_full_size },
                        .{ std.math.maxInt(@TypeOf(reported_full_size)), std.math.maxInt(@TypeOf(real_full_size)) },
                    ) catch unreachable;
                    @panic(msg.constSlice());
                }
                break :size reported_full_size;
            };

            try src.seekableStream().seekTo(0);
            self.queue_mtx.lock();
            defer self.queue_mtx.unlock();
            self.queue_pop_re.set();
            try self.queue.pushValue(self.allocator, QueueItem{
                .ctx = ctx,
                .src = src,
                .full_size = full_size,
            });
        }

        const Ctx = struct {
            ptr: *anyopaque,
            actionFn: *const fn (ptr: *anyopaque, state: Action) void,

            inline fn init(
                /// Must implement the functions:
                /// `fn update(ctx_ptr: @This(), percentage: u8) void`
                /// `fn close(ctx_ptr: @This(), src: Src, stored_file: StoredFile, encryption: chunk.EncryptionInfo) void`
                ctx_ptr: anytype,
            ) Ctx {
                const Ptr = @TypeOf(ctx_ptr);
                const gen = struct {
                    fn actionFn(erased_ptr: *anyopaque, action_data: Ctx.Action) void {
                        const ptr: Ptr = @ptrCast(@alignCast(erased_ptr));
                        switch (action_data) {
                            .update => |percentage| ptr.update(percentage),
                            .close => |args| ptr.close(args.src, args.stored_file),
                        }
                    }
                };
                return .{
                    .ptr = ctx_ptr,
                    .actionFn = gen.actionFn,
                };
            }

            pub inline fn update(self: Ctx, percentage: u8) void {
                return self.action(.{ .update = percentage });
            }

            pub inline fn close(
                self: Ctx,
                src: Src,
                stored_file: ?*const StoredFile,
            ) void {
                return self.action(.{ .close = .{
                    .src = src,
                    .stored_file = stored_file,
                } });
            }

            inline fn action(self: Ctx, data: Action) void {
                return self.actionFn(self.ptr, data);
            }
            pub const Action = union(enum) {
                update: u8,
                close: Close,

                const Close = struct {
                    src: Src,
                    stored_file: ?*const StoredFile,
                };
            };
        };

        fn uploadPipeLineThread(upp: *Self) void {
            var client = std.http.Client{ .allocator = upp.allocator };
            defer client.deinit();

            const test_key = [_]u8{0xD} ** Aes256Gcm.key_length;
            var nonce_generator: struct {
                counter: u64 = 0,
                random: std.rand.Random,

                inline fn new(this: *@This()) [Aes256Gcm.nonce_length]u8 {
                    var random_bytes: [4]u8 = undefined;
                    this.random.bytes(&random_bytes);
                    defer this.counter +%= 1;
                    return std.mem.toBytes(this.counter) ++ random_bytes;
                }
            } = .{ .random = upp.random };

            while (true) {
                const up_data: QueueItem = blk: {
                    upp.queue_pop_re.wait();

                    upp.queue_mtx.lock();
                    defer upp.queue_mtx.unlock();

                    break :blk upp.queue.popValue() orelse {
                        upp.queue_pop_re.reset();
                        if (upp.must_stop.load(must_stop_load_mo)) break;
                        continue;
                    };
                };

                const up_ctx = up_data.ctx;
                const chunk_count = chunk.countForFileSize(up_data.full_size);

                const reader = up_data.src.reader();
                const seeker = up_data.src.seekableStream();

                var stored_file: ?StoredFile = null;

                defer {
                    up_ctx.update(100);
                    up_ctx.close(
                        up_data.src,
                        if (stored_file) |*ptr| ptr else null,
                    );
                }

                // `uploadFile` seeks to 0 before pushing the source to the queue,
                // so we assume we're at the start of the source here.
                const full_file_digest = blk: {
                    // although we'll be using the array elements of this buffer later,
                    // we aren't using them yet, so we use the whole thing here first
                    // to hash large amounts of the data at a time.
                    const buffer: *[header_plus_chunk_max_size * 2]u8 = std.mem.asBytes(upp.chunk_buffers);
                    var full_file_hasher = Sha256.init(.{});

                    while (true) {
                        const byte_len = reader.readAll(buffer) catch |err| switch (err) {
                            inline else => |e| @panic("Decide how to handle " ++ @errorName(e)),
                        };
                        const data = buffer[0..byte_len];
                        if (data.len == 0) break;
                        full_file_hasher.update(data);
                    }
                    break :blk full_file_hasher.finalResult();
                };

                var eci = chunk.encryptedChunkIterator(reader, seeker, .{
                    .full_file_digest = full_file_digest,
                    .chunk_count = chunk_count,
                    .buffers = upp.chunk_buffers,
                });

                var bytes_uploaded: u64 = 0;
                const upload_size = upp.ec.totalEncodedSize(
                    chunk_count * @as(u64, chunk.Header.size) + up_data.full_size,
                );

                while (true) {
                    const result = eci.next(.{
                        .npub = &nonce_generator.new(),
                        .key = &test_key,
                    }) catch |err| switch (err) {
                        inline else => |e| @panic("Decide how to handle " ++ @errorName(e)),
                    } orelse break;

                    const chunk_name = result.name;
                    const encrypted_chunk_blob = result.encrypted;

                    var requests = util.BoundedBufferArray(std.http.Client.Request){ .buffer = upp.requests_buf };
                    defer for (requests.slice()) |*req| req.deinit();

                    if (upp.server_info.google_cloud) |gc| {
                        const gc_prealloc = upp.gc_prealloc.?;

                        var iter = gc_prealloc.bucketObjectUriIterator(gc, chunk_name);
                        while (iter.next()) |uri_str| {
                            const uri = std.Uri.parse(uri_str) catch unreachable;
                            const req = client.request(.PUT, uri, gc_prealloc.headers.toManaged(upp.allocator), .{}) catch |err| switch (err) {
                                error.OutOfMemory => @panic("TODO: actually handle this scenario in some way that isn't just panicking on this thread"),
                                inline else => |e| @panic("Decide how to handle " ++ @errorName(e)),
                            };
                            requests.appendAssumingCapacity(req);
                        }
                    }

                    for (requests.slice()) |*req| req.start() catch |err| switch (err) {
                        inline else => |e| @panic("Decide how to handle " ++ @errorName(e)),
                    };

                    const WritersCtx = struct {
                        requests: []std.http.Client.Request,
                        up_ctx: Ctx,
                        bytes_uploaded: *u64,
                        upload_size: u64,

                        const WriterCtx = struct {
                            inner: Inner,
                            up_ctx: Ctx,
                            bytes_uploaded: *u64,
                            upload_size: u64,

                            const Inner = std.http.Client.Request.Writer;
                            fn write(self: @This(), bytes: []const u8) Inner.Error!usize {
                                const written = try self.inner.write(bytes);
                                self.bytes_uploaded.* += written;
                                self.up_ctx.update(@intCast((self.bytes_uploaded.* * 100) / self.upload_size));
                                return written;
                            }
                        };
                        pub inline fn getWriter(ctx: @This(), writer_idx: u7) std.io.Writer(WriterCtx, WriterCtx.Error, WriterCtx.write) {
                            return .{ .context = .{
                                .inner = ctx.requests[writer_idx].writer(),
                                .up_ctx = ctx.up_ctx,
                                .bytes_uploaded = ctx.bytes_uploaded,
                                .upload_size = ctx.upload_size,
                            } };
                        }
                    };

                    const writers_ctx = WritersCtx{
                        .requests = requests.slice(),
                        .up_ctx = up_ctx,
                        .bytes_uploaded = &bytes_uploaded,
                        .upload_size = upload_size,
                    };

                    var ecd_fbs = std.io.fixedBufferStream(encrypted_chunk_blob);
                    _ = upp.ec.encodeCtx(ecd_fbs.reader(), writers_ctx, &.{}) catch |err| switch (err) {
                        inline else => |e| @panic("Decide how to handle " ++ @errorName(e)),
                    };
                    up_ctx.update(@intCast((bytes_uploaded * 100) / upload_size));

                    for (requests.slice()) |*req| req.finish() catch |err| @panic(switch (err) {
                        inline else => |e| "Decide how to handle " ++ @errorName(e),
                    });

                    for (@as([]std.http.Client.Request, requests.slice())) |*req| {
                        req.wait() catch |err| switch (err) {
                            error.OutOfMemory => @panic("TODO: actually handle this scenario in some way that isn't just panicking on this thread"),
                            inline else => |e| @panic("Decide how to handle " ++ @errorName(e)),
                        };
                    }
                }

                stored_file = eci.storedFile();
            }
        }
    };
}

/// Verify & return the associated namespace of `Src`.
inline fn verifySrcType(comptime Src: type) !type {
    const Ns = Ns: {
        switch (@typeInfo(Src)) {
            .Struct, .Union, .Enum => break :Ns Src,
            .Pointer => |pointer| if (pointer.size == .One)
                switch (@typeInfo(pointer.child)) {
                    .Struct, .Union, .Enum, .Opaque => switch (pointer.child) {
                        else => break :Ns pointer.child,
                        anyopaque => {},
                    },
                    else => {},
                },
            else => {},
        }
        return @field(anyerror, std.fmt.comptimePrint(
            "Expected type or pointer type with a child type with an associated namespace (struct, union, enum, typed opaque pointer), instead got '{s}'",
            .{@typeName(Src)},
        ));
    };

    const ptr_prefix = if (Src == Ns) "" else blk: {
        const info = @typeInfo(Src).Pointer;
        var prefix: []const u8 = "*";
        if (info.is_allowzero) prefix = prefix ++ "allowzero ";
        if (@sizeOf(info.child) != 0 and @alignOf(info.child) != info.alignment) {
            prefix = prefix ++ std.fmt.comptimePrint("align({d})", .{info.alignment});
        }
        if (info.address_space != @typeInfo(*anyopaque).Pointer.address_space) {
            prefix = prefix ++ std.fmt.comptimePrint("addrspace(.{s})", .{std.zig.fmtId(@tagName(info.address_space))});
        }
        if (info.is_const) prefix = prefix ++ "const ";
        if (info.is_volatile) prefix = prefix ++ "volatile ";
        break :blk prefix;
    };
    if (!@hasDecl(Ns, "Reader")) return @field(anyerror, std.fmt.comptimePrint("Expected '{s}' to contain `pub const Reader = std.io.Reader(...);`", .{@typeName(Ns)}));
    if (!@hasDecl(Ns, "reader")) return @field(anyerror, std.fmt.comptimePrint("Expected '{s}' to contain `pub fn reader(self: {s}@This()) Reader {...}`", .{ @typeName(Ns), ptr_prefix }));
    if (!@hasDecl(Ns, "SeekableStream")) return @field(anyerror, std.fmt.comptimePrint("Expected '{s}' to contain `pub const SeekableStream = std.io.SeekableStream(...);`", .{@typeName(Ns)}));
    if (!@hasDecl(Ns, "seekableStream")) return @field(anyerror, std.fmt.comptimePrint("Expected '{s}' to contain `pub fn seekableStream(self: {s}@This()) SeekableStream {...}`", .{ @typeName(Ns), ptr_prefix }));
    return Ns;
}
