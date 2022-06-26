const std = @import("../std.zig");

pub fn SeekMethods(comptime Self: type) type {
    return struct {
        pub const seek_interface_id = @typeName(Self.SeekError) ++ ".Seeker";

        pub fn seekTo(self: Self, pos: u64) Self.SeekError!void {
            return self.vtable.seekToFn(self.context, pos);
        }

        pub fn seekBy(self: Self, amt: i64) Self.SeekError!void {
            return self.vtable.seekByFn(self.context, amt);
        }

        pub fn getEndPos(self: Self) Self.GetSeekPosError!u64 {
            return self.vtable.getEndPosFn(self.context);
        }

        pub fn getPos(self: Self) Self.GetSeekPosError!u64 {
            return self.vtable.getPosFn(self.context);
        }
    };
}
