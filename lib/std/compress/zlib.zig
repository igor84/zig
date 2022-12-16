//
// Compressor/Decompressor for ZLIB data streams (RFC1950)

const std = @import("std");
const io = std.io;
const fs = std.fs;
const testing = std.testing;
const mem = std.mem;
const deflate = std.compress.deflate;

pub fn ZlibStreamReader(comptime ReaderType: type) type {
    return struct {
        const Self = @This();

        pub const Error = ReaderType.Error ||
            deflate.Decompressor(ReaderType).Error ||
            error{ WrongChecksum, Unsupported };
        pub const Reader = io.Reader(*Self, Error, read);

        allocator: mem.Allocator,
        inflater: deflate.Decompressor(ReaderType),
        in_reader: ReaderType,
        hasher: std.hash.Adler32,

        fn init(allocator: mem.Allocator, source: ReaderType) !Self {
            // Zlib header format is specified in RFC1950
            const header = try source.readBytesNoEof(2);

            const CM = @truncate(u4, header[0]);
            const CINFO = @truncate(u4, header[0] >> 4);
            const FCHECK = @truncate(u5, header[1]);
            _ = FCHECK;
            const FDICT = @truncate(u1, header[1] >> 5);

            if ((@as(u16, header[0]) << 8 | header[1]) % 31 != 0)
                return error.BadHeader;

            // The CM field must be 8 to indicate the use of DEFLATE
            if (CM != 8) return error.InvalidCompression;
            // CINFO is the base-2 logarithm of the LZ77 window size, minus 8.
            // Values above 7 are unspecified and therefore rejected.
            if (CINFO > 7) return error.InvalidWindowSize;

            const dictionary = null;
            // TODO: Support this case
            if (FDICT != 0)
                return error.Unsupported;

            return Self{
                .allocator = allocator,
                .inflater = try deflate.decompressor(allocator, source, dictionary),
                .in_reader = source,
                .hasher = std.hash.Adler32.init(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.inflater.deinit();
        }

        // Implements the io.Reader interface
        pub fn read(self: *Self, buffer: []u8) Error!usize {
            if (buffer.len == 0)
                return 0;

            // Read from the compressed stream and update the computed checksum
            const r = try self.inflater.read(buffer);
            if (r != 0) {
                self.hasher.update(buffer[0..r]);
                return r;
            }

            // We've reached the end of stream, check if the checksum matches
            const hash = try self.in_reader.readIntBig(u32);
            if (hash != self.hasher.final())
                return error.WrongChecksum;

            return 0;
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }
    };
}

pub fn zlibStreamReader(allocator: mem.Allocator, reader: anytype) !ZlibStreamReader(@TypeOf(reader)) {
    return ZlibStreamReader(@TypeOf(reader)).init(allocator, reader);
}

pub const CompressionLevel = enum(u2) {
    no_compression = 0,
    fastest = 1,
    default = 2,
    maximum = 3,
};

pub const CompressionOptions = struct {
    level: CompressionLevel = .default,
};

pub fn ZlibStreamWriter(comptime WriterType: type) type {
    return struct {
        const Self = @This();

        const Error = WriterType.Error ||
            deflate.Compressor(WriterType).Error;
        pub const Writer = io.Writer(*Self, Error, write);

        allocator: mem.Allocator,
        deflator: deflate.Compressor(WriterType),
        in_writer: WriterType,
        hasher: std.hash.Adler32,

        fn init(allocator: mem.Allocator, dest: WriterType, options: CompressionOptions) !Self {
            // Zlib header format is specified in RFC1950
            const CM: u4 = 8; // DEFLATE
            const CINFO: u4 = 7; // 32K window
            const CMF: u8 = (@as(u8, CINFO) << 4) | CM;

            const FLEVEL: u2 = @enumToInt(options.level);
            const FDICT: u1 = 0; // No preset dictionary support
            const FLG_temp = (@as(u8, FLEVEL) << 6) | (@as(u8, FDICT) << 5);
            const FCHECK: u5 = 31 - ((@as(u16, CMF) * 256 + FLG_temp) % 31);
            const FLG = FLG_temp | FCHECK;

            const compression_level: deflate.Compression = switch (options.level) {
                .no_compression => .no_compression,
                .fastest => .best_speed,
                .default => .default_compression,
                .maximum => .best_compression,
            };

            try dest.writeAll(&.{ CMF, FLG });

            return Self{
                .allocator = allocator,
                .deflator = try deflate.compressor(allocator, dest, .{ .level = compression_level }),
                .in_writer = dest,
                .hasher = std.hash.Adler32.init(),
            };
        }

        pub fn write(self: *Self, bytes: []const u8) Error!usize {
            if (bytes.len == 0) {
                return 0;
            }

            const w = try self.deflator.write(bytes);

            self.hasher.update(bytes[0..w]);
            return w;
        }

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }

        pub fn deinit(self: *Self) void {
            self.deflator.deinit();
        }

        pub fn close(self: *Self) !void {
            const hash = self.hasher.final();
            try self.deflator.close();
            try self.in_writer.writeIntBig(u32, hash);
        }
    };
}

pub fn zlibStreamWriter(allocator: mem.Allocator, writer: anytype, options: CompressionOptions) !ZlibStreamWriter(@TypeOf(writer)) {
    return ZlibStreamWriter(@TypeOf(writer)).init(allocator, writer, options);
}


fn testReader(data: []const u8, expected: []const u8) !void {
    var in_stream = io.fixedBufferStream(data);

    var zlib_stream = try zlibStreamReader(testing.allocator, in_stream.reader());
    defer zlib_stream.deinit();

    // Read and decompress the whole file
    const buf = try zlib_stream.reader().readAllAlloc(testing.allocator, std.math.maxInt(usize));
    defer testing.allocator.free(buf);

    // Check against the reference
    try testing.expectEqualSlices(u8, expected, buf);
}

// All the test cases are obtained by compressing the RFC1951 text
//
// https://tools.ietf.org/rfc/rfc1951.txt length=36944 bytes
// SHA256=5ebf4b5b7fe1c3a0c0ab9aa3ac8c0f3853a7dc484905e76e03b0b0f301350009
test "compressed data" {
    const rfc1951_txt = @embedFile("testdata/rfc1951.txt");

    // Compressed with compression level = 0
    try testReader(
        @embedFile("testdata/rfc1951.txt.z.0"),
        rfc1951_txt,
    );
    // Compressed with compression level = 9
    try testReader(
        @embedFile("testdata/rfc1951.txt.z.9"),
        rfc1951_txt,
    );
    // Compressed with compression level = 9 and fixed Huffman codes
    try testReader(
        @embedFile("testdata/rfc1951.txt.fixed.z.9"),
        rfc1951_txt,
    );
}

test "don't read past deflate stream's end" {
    try testReader(&[_]u8{
        0x08, 0xd7, 0x63, 0xf8, 0xcf, 0xc0, 0xc0, 0x00, 0xc1, 0xff,
        0xff, 0x43, 0x30, 0x03, 0x03, 0xc3, 0xff, 0xff, 0xff, 0x01,
        0x83, 0x95, 0x0b, 0xf5,
    }, &[_]u8{
        0x00, 0xff, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0xff,
        0x00, 0xff, 0xff, 0xff, 0x00, 0xff, 0xff, 0xff, 0x00, 0x00,
        0x00, 0x00, 0xff, 0xff, 0xff,
    });
}

test "sanity checks" {
    // Truncated header
    try testing.expectError(
        error.EndOfStream,
        testReader(&[_]u8{0x78}, ""),
    );
    // Failed FCHECK check
    try testing.expectError(
        error.BadHeader,
        testReader(&[_]u8{ 0x78, 0x9D }, ""),
    );
    // Wrong CM
    try testing.expectError(
        error.InvalidCompression,
        testReader(&[_]u8{ 0x79, 0x94 }, ""),
    );
    // Wrong CINFO
    try testing.expectError(
        error.InvalidWindowSize,
        testReader(&[_]u8{ 0x88, 0x98 }, ""),
    );
    // Wrong checksum
    try testing.expectError(
        error.WrongChecksum,
        testReader(&[_]u8{ 0x78, 0xda, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00 }, ""),
    );
    // Truncated checksum
    try testing.expectError(
        error.EndOfStream,
        testReader(&[_]u8{ 0x78, 0xda, 0x03, 0x00, 0x00 }, ""),
    );
}

test "compress data" {
    const allocator = testing.allocator;
    const rfc1951_txt = @embedFile("testdata/rfc1951.txt");

    var compressed_data = std.ArrayList(u8).init(allocator);
    defer compressed_data.deinit();

    var compressor = try zlibStreamWriter(allocator, compressed_data.writer(), .{});
    defer compressor.deinit();

    try compressor.writer().writeAll(rfc1951_txt);
    try compressor.close();

    try testReader(compressed_data.items, rfc1951_txt);
}
