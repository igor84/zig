const std = @import("../std.zig");
const assert = std.debug.assert;
const mem = std.mem;
const SeekMethods = std.io.SeekMethods;

pub fn Writer(comptime WriteError: type) type {
    return struct {
        context: *anyopaque,
        vtable: *const VTable,

        pub const Error = WriteError;
        const Self = @This();

        const VTable = struct {
            writeFn: fn (*anyopaque, []const u8) Error!usize,
        };

        pub fn init(comptime T: type, ctx: *T, comptime writeFn: fn(*T, []const u8) Error!usize) Self {
            const gen = struct {
                fn writeImpl(ptr: *anyopaque, bytes: []u8) Error!usize {
                    return writeFn(@ptrCast(*T, @alignCast(@alignOf(T), ptr)), bytes);
                }

                const vtable = VTable { .writeFn = writeImpl };
            };

            return . { .context = ctx, .vtable = &gen.vtable };
        }

        pub usingnamespace WriterMethods(Self);
    };
}

pub fn SeekableWriter(
    comptime WriteError: type,
    comptime SeekErrorType: type,
    comptime GetSeekPosErrorType: type,
    
) type {
    return struct {
        context: *anyopaque,
        vtable: *const VTable,

        pub const Error = WriteError;
        pub const SeekError = SeekErrorType;
        pub const GetSeekPosError = GetSeekPosErrorType;
        const Self = @This();

        const VTable = struct {
            writeFn: fn (*anyopaque, []const u8) Error!usize,
            seekToFn: fn (*anyopaque, pos: u64) SeekError!void,
            seekByFn: fn (*anyopaque, amt: i64) SeekError!void,
            getEndPosFn: fn (*anyopaque) GetSeekPosError!u64,
            getPosFn: fn (*anyopaque) GetSeekPosError!u64,
        };

        pub fn init(
            comptime T: type,
            ctx: *T,
            comptime writeFn: fn(*T, []const u8) Error!usize,
            comptime seekToFn: fn(*T, pos: u64) SeekError!void,
            comptime seekByFn: fn(*T, amt: i64) SeekError!void,
            comptime getEndPosFn: fn(*T)  GetSeekPosError!u64,
            comptime getPosFn: fn(*T)  GetSeekPosError!u64,
        ) Self {
            const gen = struct {
                fn writeImpl(ptr: *anyopaque, bytes: []const u8) Error!usize {
                    return writeFn(@ptrCast(*T, @alignCast(@alignOf(T), ptr)), bytes);
                }

                fn seekToImpl(ptr: *anyopaque, pos: u64) SeekError!void {
                    return seekToFn(@ptrCast(*T, @alignCast(@alignOf(T), ptr)), pos);
                }

                fn seekByImpl(ptr: *anyopaque, amt: i64) SeekError!void {
                    return seekByFn(@ptrCast(*T, @alignCast(@alignOf(T), ptr)), amt);
                }

                fn getEndPosImpl(ptr: *anyopaque) GetSeekPosError!u64 {
                    return getEndPosFn(@ptrCast(*T, @alignCast(@alignOf(T), ptr)));
                }

                fn getPosImpl(ptr: *anyopaque) GetSeekPosError!u64 {
                    return getPosFn(@ptrCast(*T, @alignCast(@alignOf(T), ptr)));
                }

                const vtable = VTable{
                    .writeFn = writeImpl,
                    .seekToFn = seekToImpl,
                    .seekByFn = seekByImpl,
                    .getEndPosFn = getEndPosImpl,
                    .getPosFn = getPosImpl,
                };
            };

            return .{
                .context = ctx,
                .vtable = &gen.vtable,
            };
        }

        pub usingnamespace WriterMethods(Self);

        pub usingnamespace SeekMethods(Self);
    };
}

pub fn WriterMethods(comptime Self: type) type {
    return struct {
        pub fn write(self: Self, bytes: []const u8) Self.Error!usize {
            return self.vtable.writeFn(self.context, bytes);
        }

        pub fn writeAll(self: Self, bytes: []const u8) Self.Error!void {
            var index: usize = 0;
            while (index != bytes.len) {
                index += try self.write(bytes[index..]);
            }
        }

        pub fn print(self: Self, comptime format: []const u8, args: anytype) Self.Error!void {
            return std.fmt.format(self, format, args);
        }

        pub fn writeByte(self: Self, byte: u8) Self.Error!void {
            const array = [1]u8{byte};
            return self.writeAll(&array);
        }

        pub fn writeByteNTimes(self: Self, byte: u8, n: usize) Self.Error!void {
            var bytes: [256]u8 = undefined;
            mem.set(u8, bytes[0..], byte);

            var remaining: usize = n;
            while (remaining > 0) {
                const to_write = std.math.min(remaining, bytes.len);
                try self.writeAll(bytes[0..to_write]);
                remaining -= to_write;
            }
        }

        /// Write a native-endian integer.
        /// TODO audit non-power-of-two int sizes
        pub fn writeIntNative(self: Self, comptime T: type, value: T) Self.Error!void {
            var bytes: [(@typeInfo(T).Int.bits + 7) / 8]u8 = undefined;
            mem.writeIntNative(T, &bytes, value);
            return self.writeAll(&bytes);
        }

        /// Write a foreign-endian integer.
        /// TODO audit non-power-of-two int sizes
        pub fn writeIntForeign(self: Self, comptime T: type, value: T) Self.Error!void {
            var bytes: [(@typeInfo(T).Int.bits + 7) / 8]u8 = undefined;
            mem.writeIntForeign(T, &bytes, value);
            return self.writeAll(&bytes);
        }

        /// TODO audit non-power-of-two int sizes
        pub fn writeIntLittle(self: Self, comptime T: type, value: T) Self.Error!void {
            var bytes: [(@typeInfo(T).Int.bits + 7) / 8]u8 = undefined;
            mem.writeIntLittle(T, &bytes, value);
            return self.writeAll(&bytes);
        }

        /// TODO audit non-power-of-two int sizes
        pub fn writeIntBig(self: Self, comptime T: type, value: T) Self.Error!void {
            var bytes: [(@typeInfo(T).Int.bits + 7) / 8]u8 = undefined;
            mem.writeIntBig(T, &bytes, value);
            return self.writeAll(&bytes);
        }

        /// TODO audit non-power-of-two int sizes
        pub fn writeInt(self: Self, comptime T: type, value: T, endian: std.builtin.Endian) Self.Error!void {
            var bytes: [(@typeInfo(T).Int.bits + 7) / 8]u8 = undefined;
            mem.writeInt(T, &bytes, value, endian);
            return self.writeAll(&bytes);
        }

        pub fn writeStruct(self: Self, value: anytype) Self.Error!void {
            // Only extern and packed structs have defined in-memory layout.
            comptime assert(@typeInfo(@TypeOf(value)).Struct.layout != .Auto);
            return self.writeAll(mem.asBytes(&value));
        }
    };
}
