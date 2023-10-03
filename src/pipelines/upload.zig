const chunk = @import("chunk.zig");
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
        allocator: std.mem.Allocator,
        requests_buf: []std.http.Client.Request,
        server_info: ServerInfo,
        gc_prealloc: ?ServerInfo.GoogleCloud.PreAllocated,

        must_stop: std.atomic.Atomic(bool),
        queue_mtx: std.Thread.Mutex,
        queue: ManagedQueue(QueueItem),

        chunk_headers_buf_mtx: std.Thread.Mutex,
        chunk_headers_buf: std.MultiArrayList(ChunkHeaderInfo),
        chunk_buffer: *[header_plus_chunk_max_size * 2]u8,

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
        const ChunkHeaderInfo = struct { header: chunk.Header };

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
                .requests_buf = &.{},
                .server_info = values.server_info,
                .gc_prealloc = null,

                .must_stop = std.atomic.Atomic(bool).init(false),
                .queue_mtx = .{},
                .queue = undefined,

                .chunk_headers_buf_mtx = .{},
                .chunk_headers_buf = .{},
                .chunk_buffer = undefined,

                .random = values.random,
                .ec = undefined,
                .thread = null,
            };

            self.requests_buf = try self.allocator.alloc(std.http.Client.Request, values.server_info.bucketCount());
            errdefer self.allocator.free(self.requests_buf);

            if (values.server_info.google_cloud) |gc| {
                self.gc_prealloc = try gc.preAllocated(self.allocator);
            }
            errdefer if (self.gc_prealloc) |pre_alloc| pre_alloc.deinit(self.allocator);

            self.queue = try ManagedQueue(QueueItem).initCapacity(self.allocator, values.queue_capacity);
            errdefer self.queue.deinit(self.allocator);

            self.chunk_buffer = try self.allocator.create([header_plus_chunk_max_size * 2]u8);
            errdefer self.allocator.free(self.chunk_buffer);

            self.ec = try ErasureCoder.init(self.allocator, .{
                .shard_count = @intCast(values.server_info.bucketCount()),
                .shards_required = values.server_info.shards_required,
            });
            errdefer self.ec.deinit(self.allocator);

            return self;
        }

        pub inline fn start(self: *Self) !void {
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
            if (self.thread) |thread| thread.join();
            self.queue.deinit(self.allocator);

            self.chunk_headers_buf.deinit(self.allocator);
            self.allocator.free(self.chunk_buffer);

            self.ec.deinit(self.allocator);
            self.allocator.free(self.requests_buf);
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

            {
                self.chunk_headers_buf_mtx.lock();
                defer self.chunk_headers_buf_mtx.unlock();
                try self.chunk_headers_buf.ensureTotalCapacity(self.allocator, chunk.countForFileSize(full_size));
            }

            {
                try src.seekableStream().seekTo(0);
                self.queue_mtx.lock();
                defer self.queue_mtx.unlock();
                try self.queue.pushValue(self.allocator, QueueItem{
                    .ctx = ctx,
                    .src = src,
                    .full_size = full_size,
                });
            }
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

            const hpcms = header_plus_chunk_max_size;
            const decrypted_chunk_buffer: *[hpcms]u8 = upp.chunk_buffer[hpcms * 0 ..][0..hpcms];
            const encrypted_chunk_buffer: *[hpcms]u8 = upp.chunk_buffer[hpcms * 1 ..][0..hpcms];

            const test_key = [_]u8{0xD} ** Aes256Gcm.key_length;

            const NonceGenerator = struct {
                counter: u64 = 0,
                random: std.rand.Random,

                inline fn new(this: *@This()) [Aes256Gcm.nonce_length]u8 {
                    const counter_value = this.counter;
                    this.counter +%= 1;
                    var random_bytes: [4]u8 = undefined;
                    this.random.bytes(&random_bytes);
                    return std.mem.toBytes(counter_value) ++ random_bytes;
                }
            };
            var nonce_generator = NonceGenerator{ .random = upp.random };

            while (true) {
                const up_data: QueueItem = blk: {
                    upp.queue_mtx.lock();
                    defer upp.queue_mtx.unlock();
                    break :blk upp.queue.popValue() orelse {
                        if (upp.must_stop.load(must_stop_load_mo)) break;
                        std.atomic.spinLoopHint();
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

                    upp.chunk_headers_buf_mtx.lock();
                    defer upp.chunk_headers_buf_mtx.unlock();
                    up_ctx.close(
                        up_data.src,
                        if (stored_file) |*ptr| ptr else null,
                    );
                }

                // clear chunk header buffer
                // NOTE: this should be safe as the `len` field is never touched by the other thread,
                // and this doesn't touch the capacity, which is only ever touched by the other thread.
                upp.chunk_headers_buf.shrinkRetainingCapacity(0);

                { // full SHA calculation & first step of chunk headers initialisation
                    var full_hasher = Sha256.init(.{});

                    seeker.seekTo(0) catch |err| switch (err) {
                        inline else => |e| @panic("Decide how to handle " ++ @errorName(e)),
                    };
                    var real_chunk_count: chunk.Count = 0;
                    while (true) {
                        const chunk_buffer: *[chunk.size]u8 = upp.chunk_buffer[chunk.Header.size..][0..chunk.size];
                        const bytes_read = reader.readAll(chunk_buffer) catch |err| switch (err) {
                            inline else => |e| @panic("Decide how to handle " ++ @errorName(e)),
                        };
                        const chunk_data = chunk_buffer[0..bytes_read];
                        if (chunk_data.len == 0) break;

                        real_chunk_count += 1;

                        full_hasher.update(chunk_data);
                        const chunk_digest = sha: {
                            var chunk_sha: [Sha256.digest_length]u8 = undefined;
                            Sha256.hash(chunk_data, &chunk_sha, .{});
                            break :sha chunk_sha;
                        };

                        upp.chunk_headers_buf_mtx.lock();
                        defer upp.chunk_headers_buf_mtx.unlock();

                        upp.chunk_headers_buf.appendAssumeCapacity(ChunkHeaderInfo{
                            .header = chunk.Header{
                                .current_chunk_digest = chunk_digest,
                                .full_file_digest = .{0} ** Sha256.digest_length,
                                .next = .{
                                    .chunk_blob_digest = .{0} ** Sha256.digest_length,
                                    .encryption = .{
                                        .tag = .{0} ** Aes256Gcm.tag_length,
                                        .npub = .{0} ** Aes256Gcm.nonce_length,
                                        .key = .{0} ** Aes256Gcm.key_length,
                                    },
                                },
                            },
                        });
                    }
                    switch (std.math.order(real_chunk_count, chunk_count)) {
                        .eq => {},
                        .lt => @panic("TODO handle: fewer chunks present than reported"),
                        .gt => @panic("TODO handle: more chunks present than reported"),
                    }

                    const full_file_digest = full_hasher.finalResult();

                    upp.chunk_headers_buf_mtx.lock();
                    defer upp.chunk_headers_buf_mtx.unlock();

                    const headers: []chunk.Header = upp.chunk_headers_buf.items(.header);
                    assert(headers.len != 0);

                    const first = &headers[0];
                    first.* = .{
                        .current_chunk_digest = first.current_chunk_digest,
                        .full_file_digest = full_file_digest,
                        .next = .{
                            .chunk_blob_digest = .{0} ** Sha256.digest_length,
                            .encryption = .{
                                .tag = .{0} ** Aes256Gcm.tag_length,
                                .npub = .{0} ** Aes256Gcm.nonce_length,
                                .key = .{0} ** Aes256Gcm.key_length,
                            },
                        },
                    };
                }
                assert(upp.chunk_headers_buf.len == chunk_count);

                var bytes_uploaded: u64 = 0;
                const upload_size = upp.ec.totalEncodedSize(
                    chunk_count * @as(u64, chunk.Header.size) + up_data.full_size,
                );

                for (1 + 0..1 + chunk_count) |rev_chunk_idx_uncasted| {
                    const chunk_idx: chunk.Count = @intCast(chunk_count - rev_chunk_idx_uncasted);
                    const chunk_offset = chunk.startOffset(chunk_idx);

                    const current_header: chunk.Header = blk: {
                        upp.chunk_headers_buf_mtx.lock();
                        defer upp.chunk_headers_buf_mtx.unlock();

                        const headers = upp.chunk_headers_buf.items(.header);
                        break :blk headers[chunk_idx];
                    };
                    decrypted_chunk_buffer[0..chunk.Header.size].* = current_header.toBytes();

                    // the entire unencrypted header bytes and data bytes of the current block
                    const decrypted_chunk_blob: []const u8 = blk: {
                        const buffer_subsection: *[chunk.size]u8 = decrypted_chunk_buffer[chunk.Header.size..];
                        seeker.seekTo(chunk_offset) catch |err| switch (err) {
                            inline else => |e| @panic("Decide how to handle " ++ @errorName(e)),
                        };
                        const bytes_len = reader.readAll(buffer_subsection) catch |err| switch (err) {
                            inline else => |e| @panic("Decide how to handle " ++ @errorName(e)),
                        };
                        break :blk decrypted_chunk_buffer[0 .. chunk.Header.size + bytes_len];
                    };

                    var auth_tag: [Aes256Gcm.tag_length]u8 = undefined;
                    const npub = nonce_generator.new();

                    Aes256Gcm.encrypt(
                        encrypted_chunk_buffer[0..decrypted_chunk_blob.len],
                        &auth_tag,
                        decrypted_chunk_blob,
                        "",
                        npub,
                        test_key,
                    );
                    const encrypted_chunk_blob: []const u8 = encrypted_chunk_buffer[0..decrypted_chunk_blob.len];

                    const chunk_name = blk: {
                        var chunk_name: [Sha256.digest_length]u8 = undefined;
                        Sha256.hash(encrypted_chunk_blob, &chunk_name, .{});
                        break :blk chunk_name;
                    };

                    {
                        upp.chunk_headers_buf_mtx.lock();
                        defer upp.chunk_headers_buf_mtx.unlock();

                        const slice = upp.chunk_headers_buf.slice();

                        if (chunk_idx != 0) { // initialise the `next_chunk_blob_digest` field of the previous chunk (it is the next in the iteration order)
                            const headers: []chunk.Header = slice.items(.header);
                            headers[chunk_idx - 1].next = .{
                                .chunk_blob_digest = chunk_name,
                                .encryption = .{
                                    .tag = auth_tag,
                                    .npub = npub,
                                    .key = test_key,
                                },
                            };
                        } else {
                            assert(stored_file == null);
                            stored_file = .{
                                .encryption = .{
                                    .tag = auth_tag,
                                    .npub = npub,
                                    .key = test_key,
                                },
                                .first_name = chunk_name,
                                .chunk_count = chunk_count,
                            };
                        }
                    }

                    var requests = util.BoundedBufferArray(std.http.Client.Request){ .buffer = upp.requests_buf };
                    defer for (requests.slice()) |*req| req.deinit();

                    if (upp.server_info.google_cloud) |gc| {
                        const gc_prealloc = upp.gc_prealloc.?;

                        var iter = gc_prealloc.bucketObjectUriIterator(gc, &chunk_name);
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
                            const Error = Inner.Error;
                            fn write(self: @This(), bytes: []const u8) Error!usize {
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
