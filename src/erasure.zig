const std = @import("std");
const mat = @import("field_matrix.zig");
const math = @import("math.zig");

pub const WordSize = enum(u8) {
    One = 1,
    Four = 4,
    Eight = 8,
};

pub fn ErasureCoder(comptime n: comptime_int, comptime k: comptime_int, comptime w: WordSize) type {
    return struct {
        const exp: u8 = math.ceil_binary(n + k);
        const word_size: u8 = @intFromEnum(w);
        const word_type: type = switch (w) {
            .One => u8,
            .Four => u32,
            .Eight => u64,
        };

        encoder: mat.BinaryFieldMatrix(n, k, exp) = undefined,
        chunk_size: usize = undefined,
        data_block_size: usize = undefined,
        code_block_size: usize = undefined,

        const Self = @This();

        pub const ReadStatus = struct {
            block: [exp * k]word_type,
            size: usize,
            done: bool,
        };

        pub fn init(allocator: std.mem.Allocator) !Self {
            const w_int = @intFromEnum(w);
            const chunk_size = w_int * exp;

            return .{
                .encoder = try mat.BinaryFieldMatrix(n, k, exp).initCauchy(allocator),
                .chunk_size = chunk_size,
                .data_block_size = chunk_size * k,
                .code_block_size = chunk_size * n,
            };
        }

        pub fn deinit(self: *Self) void {
            self.encoder.deinit();
        }

        pub fn readDataBlock(self: *Self, in_fifo: std.fs.File.Reader) !ReadStatus {
            var rs = ReadStatus{
                .done = false,
                .size = 0,
                .block = std.mem.zeroes([exp * k]word_type),
            };

            var block_size: usize = 0;
            var buffer: [word_size]u8 = std.mem.zeroes([word_size]u8);

            for (0..rs.block.len) |i| {
                var read_size = try in_fifo.read(&buffer);
                std.debug.print("read size={d}\n", .{read_size});
                block_size += read_size;
                if (read_size < buffer.len) {
                    std.debug.print("block size={d}\n", .{block_size});
                    buffer[buffer.len - 1] = @intCast(block_size);
                }
                rs.block[i] = std.mem.readIntBig(word_type, &buffer);
                std.debug.print("read int {d}\n", .{rs.block[i]});
            }
            rs.size = block_size;
            std.debug.print("return size {d}\n", .{rs.size});
            rs.done = block_size < self.data_block_size;
            std.debug.print("return done {}\n", .{rs.done});
            return rs;
        }

        pub fn readCodeBlock(_: *Self, in_fifos: []std.fs.File.Reader) !ReadStatus {
            var rs = ReadStatus{
                .done = false,
                .size = 0,
                .block = std.mem.zeroes([exp * k]word_type),
            };

            var buffer: [word_size]u8 = std.mem.zeroes([word_size]u8);

            for (0..rs.block.len) |i| {
                var p = i / exp;
                var read_size = try in_fifos[p].read(&buffer);
                std.debug.assert(read_size == buffer.len);
                rs.block[i] = std.mem.readIntBig(word_type, &buffer);
            }
            var p = (rs.block.len - 1) / exp;
            rs.size = try in_fifos[p].read(&buffer);
            rs.done = rs.size == 0;
            return rs;
        }

        pub fn writeCodeBlock(_: *Self, encoder: mat.BinaryFieldMatrix(n * exp, k * exp, 1), data_block: [exp * k]word_type, out_fifos: []std.fs.File.Writer) !void {
            var code_block = std.mem.zeroes([exp * n]word_type);
            var buffer = std.mem.zeroes([word_size]u8);

            for (0..code_block.len) |i| {
                for (0..encoder.numCols) |j| {
                    if (encoder.get(i, j) == 1) {
                        code_block[i] ^= data_block[j];
                    }
                }
                std.mem.writeIntBig(word_type, &buffer, code_block[i]);
                var p = i / exp;
                _ = try out_fifos[p].write(&buffer);
            }
        }

        pub fn writeDataBlock(self: *Self, decoder: mat.BinaryFieldMatrix(k * exp, k * exp, 1), code_block: [exp * k]word_type, out_fifo: std.fs.File.Writer, done: bool) !usize {
            var data_block = std.mem.zeroes([exp * k]word_type);
            var data_block_size: usize = 0;
            var buffer: [exp * k][word_size]u8 = undefined;

            for (0..data_block.len) |i| {
                for (0..decoder.numCols) |j| {
                    if (decoder.get(i, j) == 1) {
                        data_block[i] ^= code_block[j];
                    }
                }
                std.mem.writeIntBig(word_type, &buffer[i], data_block[i]);
            }
            if (done) {
                data_block_size = buffer[buffer.len - 1][buffer[0].len - 1];
            } else {
                data_block_size = self.data_block_size;
            }
            var written_size: usize = 0;
            for (0..buffer.len) |i| {
                if ((written_size + word_size) <= data_block_size) {
                    _ = try out_fifo.write(&buffer[i]);
                    written_size += word_size;
                } else {
                    _ = try out_fifo.write(buffer[i][0..(data_block_size - written_size)]);
                    written_size = data_block_size;
                    break;
                }
            }
            return data_block_size;
        }

        pub fn encode(self: *Self, in_fifo: std.fs.File.Reader, out_fifos: []std.fs.File.Writer) !usize {
            std.debug.assert(out_fifos.len == n);
            var encoder_bin = try self.encoder.toBinary();
            defer encoder_bin.deinit();
            var size: usize = 0;
            var done = false;
            while (!done) {
                std.debug.print("reading data block\n", .{});
                var rs = try self.readDataBlock(in_fifo);
                done = rs.done;
                std.debug.print("done = {}\n", .{done});
                std.debug.print("writing code block\n", .{});
                _ = try self.writeCodeBlock(encoder_bin, rs.block, out_fifos);
                if (!done) {
                    size += self.data_block_size;
                    std.debug.print("!done size = {d}\n", .{size});
                } else {
                    var buffer = std.mem.zeroes([word_size]u8);
                    std.mem.writeIntBig(word_type, &buffer, rs.block[rs.block.len - 1]);
                    size += buffer[buffer.len - 1];
                    std.debug.print("done size = {d}\n", .{size});
                }
            }
            return size;
        }

        pub fn decode(self: *Self, excluded_shards: []u8, in_fifos: []std.fs.File.Reader, out_fifo: std.fs.File.Writer) !usize {
            std.debug.assert(excluded_shards.len == (n - k));
            std.debug.assert(in_fifos.len == k);
            var decoder_sub = try self.encoder.subMatrix(n - k, 0, excluded_shards, &[0]u8{});
            defer decoder_sub.deinit();
            var decoder_inv = try decoder_sub.invert();
            defer decoder_inv.deinit();
            var decoder_bin = try decoder_inv.toBinary();
            defer decoder_bin.deinit();

            var size: usize = 0;
            var done = false;
            while (!done) {
                var rs = try self.readCodeBlock(in_fifos);
                done = rs.done;
                var write_size = try self.writeDataBlock(decoder_bin, rs.block, out_fifo, done);
                size += write_size;
            }
            return size;
        }
    };
}

fn sample(r: std.rand.Random, comptime max: u8, comptime num: u8) [num]u8 {
    var nums: [num]u8 = std.mem.zeroes([num]u8);
    var i: usize = 0;
    while (i < num) {
        var new = r.uintLessThan(u8, max);
        var done = true;
        for (0..i) |j| {
            if (nums[j] == new) {
                done = false;
            }
        }
        if (done) {
            nums[i] = new;
            i += 1;
        }
    }
    return nums;
}

fn in(set: []u8, n: u8) bool {
    for (0..set.len) |i| {
        if (n == set[i]) {
            return true;
        }
    }
    return false;
}

fn notIn(set: []u8, n: u8) bool {
    return !in(set, n);
}

test "erasure coder" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var ec = try ErasureCoder(5, 3, WordSize.Eight).init(std.testing.allocator);
    defer ec.deinit();
    var data_filename = "temp_data_file";
    var data_file = try tmp.dir.createFile(data_filename, .{});
    try data_file.writer().writeAll("The quick brown fox jumps over the lazy dog.");
    data_file.close();

    var decoded_filename = "temp_decoded_data_file";
    var decoded_file = try tmp.dir.createFile(decoded_filename, .{});

    var code_filenames = [_][]const u8{ "temp_code_file_1", "temp_code_file_2", "temp_code_file_3", "temp_code_file_4", "temp_code_file_5" };
    var code_files: [5]std.fs.File = undefined;
    for (0..code_filenames.len) |i| {
        code_files[i] = try tmp.dir.createFile(code_filenames[i], .{});
    }

    // encode
    var code_writers: [5]std.fs.File.Writer = undefined;
    for (0..code_files.len) |i| {
        code_writers[i] = code_files[i].writer();
    }
    var data_in = try tmp.dir.openFile(data_filename, .{});
    var data_size = try ec.encode(data_in.reader(), &code_writers);
    try std.testing.expect(data_size > 0);
    for (0..code_files.len) |i| {
        code_files[i].close();
    }
    data_in.close();

    // decode
    var prng = std.rand.DefaultPrng.init(1234);
    var random = prng.random();
    var excluded_shards = sample(random, 5, 2);
    var code_in: [3]std.fs.File = undefined;
    var code_readers: [3]std.fs.File.Reader = undefined;
    var j: usize = 0;
    for (0..code_filenames.len) |i| {
        if (notIn(&excluded_shards, @intCast(i))) {
            code_in[j] = try tmp.dir.openFile(code_filenames[i], .{});
            code_readers[j] = code_in[j].reader();
            j += 1;
        }
    }
    defer for (code_in) |f| {
        f.close();
    };
    var decoded_size = try ec.decode(&excluded_shards, &code_readers, decoded_file.writer());
    defer decoded_file.close();
    try std.testing.expectEqual(data_size, decoded_size);
    var buffer = std.mem.zeroes([256]u8);
    var decoded_in = try tmp.dir.openFile(data_filename, .{});
    defer decoded_in.close();
    var buffer_size = try decoded_in.reader().readAll(&buffer);
    std.debug.print("decoded: {s}\n", .{buffer[0..buffer_size]});
}
