//! To get started, run this tool with no args and read the help message.
//!
//! This tool extracts the Linux syscall numbers from the Linux source tree
//! directly, and emits an enumerated list per supported Zig arch.

const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const zig = std.zig;
const fs = std.fs;

const stdlib_renames = std.StaticStringMap([]const u8).initComptime(.{
    // Most 64-bit archs.
    .{ "newfstatat", "fstatat64" },
    // POWER.
    .{ "sync_file_range2", "sync_file_range" },
    // ARM EABI/Thumb.
    .{ "arm_sync_file_range", "sync_file_range" },
    .{ "arm_fadvise64_64", "fadvise64_64" },
});

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len < 3 or mem.eql(u8, args[1], "--help"))
        usageAndExit(std.io.getStdErr(), args[0], 1);
    const zig_exe = args[1];
    const linux_path = args[2];

    var buf_out = std.io.bufferedWriter(std.io.getStdOut().writer());
    const writer = buf_out.writer();

    // As of 5.17.1, the largest table is 23467 bytes.
    // 32k should be enough for now.
    const buf = try allocator.alloc(u8, 1 << 15);
    const linux_dir = try std.fs.openDirAbsolute(linux_path, .{});

    try writer.writeAll(
        \\// This file is automatically generated.
        \\// See tools/generate_linux_syscalls.zig for more info.
        \\
        \\
    );

    // These architectures have their syscall definitions generated from a TSV
    // file, processed via scripts/syscallhdr.sh.
    {
        try writer.writeAll("pub const X86 = enum(usize) {\n");

        const table = try linux_dir.readFile("arch/x86/entry/syscalls/syscall_32.tbl", buf);
        var lines = mem.tokenizeScalar(u8, table, '\n');
        while (lines.next()) |line| {
            if (line[0] == '#') continue;

            var fields = mem.tokenizeAny(u8, line, " \t");
            const number = fields.next() orelse return error.Incomplete;
            // abi is always i386
            _ = fields.next() orelse return error.Incomplete;
            const name = fields.next() orelse return error.Incomplete;

            try writer.print("    {p} = {s},\n", .{ zig.fmtId(name), number });
        }

        try writer.writeAll("};\n\n");
    }
    {
        try writer.writeAll("pub const X64 = enum(usize) {\n");

        const table = try linux_dir.readFile("arch/x86/entry/syscalls/syscall_64.tbl", buf);
        var lines = mem.tokenizeScalar(u8, table, '\n');
        while (lines.next()) |line| {
            if (line[0] == '#') continue;

            var fields = mem.tokenizeAny(u8, line, " \t");
            const number = fields.next() orelse return error.Incomplete;
            const abi = fields.next() orelse return error.Incomplete;
            // The x32 abi syscalls are always at the end.
            if (mem.eql(u8, abi, "x32")) break;
            const name = fields.next() orelse return error.Incomplete;

            const fixed_name = if (stdlib_renames.get(name)) |fixed| fixed else name;
            try writer.print("    {p} = {s},\n", .{ zig.fmtId(fixed_name), number });
        }

        try writer.writeAll("};\n\n");
    }
    {
        try writer.writeAll(
            \\pub const Arm = enum(usize) {
            \\    const arm_base = 0x0f0000;
            \\
            \\
        );

        const table = try linux_dir.readFile("arch/arm/tools/syscall.tbl", buf);
        var lines = mem.tokenizeScalar(u8, table, '\n');
        while (lines.next()) |line| {
            if (line[0] == '#') continue;

            var fields = mem.tokenizeAny(u8, line, " \t");
            const number = fields.next() orelse return error.Incomplete;
            const abi = fields.next() orelse return error.Incomplete;
            if (mem.eql(u8, abi, "oabi")) continue;
            const name = fields.next() orelse return error.Incomplete;

            const fixed_name = if (stdlib_renames.get(name)) |fixed| fixed else name;
            try writer.print("    {p} = {s},\n", .{ zig.fmtId(fixed_name), number });
        }

        // TODO: maybe extract these from arch/arm/include/uapi/asm/unistd.h
        try writer.writeAll(
            \\
            \\    breakpoint = arm_base + 1,
            \\    cacheflush = arm_base + 2,
            \\    usr26 = arm_base + 3,
            \\    usr32 = arm_base + 4,
            \\    set_tls = arm_base + 5,
            \\    get_tls = arm_base + 6,
            \\};
            \\
            \\
        );
    }
    {
        try writer.writeAll("pub const Sparc64 = enum(usize) {\n");
        const table = try linux_dir.readFile("arch/sparc/kernel/syscalls/syscall.tbl", buf);
        var lines = mem.tokenizeScalar(u8, table, '\n');
        while (lines.next()) |line| {
            if (line[0] == '#') continue;

            var fields = mem.tokenizeAny(u8, line, " \t");
            const number = fields.next() orelse return error.Incomplete;
            const abi = fields.next() orelse return error.Incomplete;
            if (mem.eql(u8, abi, "32")) continue;
            const name = fields.next() orelse return error.Incomplete;

            try writer.print("    {p} = {s},\n", .{ zig.fmtId(name), number });
        }

        try writer.writeAll("};\n\n");
    }
    {
        try writer.writeAll(
            \\pub const Mips = enum(usize) {
            \\    pub const Linux = 4000;
            \\
            \\
        );

        const table = try linux_dir.readFile("arch/mips/kernel/syscalls/syscall_o32.tbl", buf);
        var lines = mem.tokenizeScalar(u8, table, '\n');
        while (lines.next()) |line| {
            if (line[0] == '#') continue;

            var fields = mem.tokenizeAny(u8, line, " \t");
            const number = fields.next() orelse return error.Incomplete;
            // abi is always o32
            _ = fields.next() orelse return error.Incomplete;
            const name = fields.next() orelse return error.Incomplete;
            if (mem.startsWith(u8, name, "unused")) continue;

            try writer.print("    {p} = Linux + {s},\n", .{ zig.fmtId(name), number });
        }

        try writer.writeAll("};\n\n");
    }
    {
        try writer.writeAll(
            \\pub const Mips64 = enum(usize) {
            \\    pub const Linux = 5000;
            \\
            \\
        );

        const table = try linux_dir.readFile("arch/mips/kernel/syscalls/syscall_n64.tbl", buf);
        var lines = mem.tokenizeScalar(u8, table, '\n');
        while (lines.next()) |line| {
            if (line[0] == '#') continue;

            var fields = mem.tokenizeAny(u8, line, " \t");
            const number = fields.next() orelse return error.Incomplete;
            // abi is always n64
            _ = fields.next() orelse return error.Incomplete;
            const name = fields.next() orelse return error.Incomplete;
            const fixed_name = if (stdlib_renames.get(name)) |fixed| fixed else name;

            try writer.print("    {p} = Linux + {s},\n", .{ zig.fmtId(fixed_name), number });
        }

        try writer.writeAll("};\n\n");
    }
    {
        try writer.writeAll("pub const PowerPC = enum(usize) {\n");

        const table = try linux_dir.readFile("arch/powerpc/kernel/syscalls/syscall.tbl", buf);
        var list_64 = std.ArrayList(u8).init(allocator);
        var lines = mem.tokenizeScalar(u8, table, '\n');
        while (lines.next()) |line| {
            if (line[0] == '#') continue;

            var fields = mem.tokenizeAny(u8, line, " \t");
            const number = fields.next() orelse return error.Incomplete;
            const abi = fields.next() orelse return error.Incomplete;
            const name = fields.next() orelse return error.Incomplete;
            const fixed_name = if (stdlib_renames.get(name)) |fixed| fixed else name;

            if (mem.eql(u8, abi, "spu")) {
                continue;
            } else if (mem.eql(u8, abi, "32")) {
                try writer.print("    {p} = {s},\n", .{ zig.fmtId(fixed_name), number });
            } else if (mem.eql(u8, abi, "64")) {
                try list_64.writer().print("    {p} = {s},\n", .{ zig.fmtId(fixed_name), number });
            } else { // common/nospu
                try writer.print("    {p} = {s},\n", .{ zig.fmtId(fixed_name), number });
                try list_64.writer().print("    {p} = {s},\n", .{ zig.fmtId(fixed_name), number });
            }
        }

        try writer.writeAll(
            \\};
            \\
            \\pub const PowerPC64 = enum(usize) {
            \\
        );
        try writer.writeAll(list_64.items);
        try writer.writeAll("};\n\n");
    }

    // Newer architectures (starting with aarch64 c. 2012) now use the same C
    // header file for their syscall numbers. Arch-specific headers are used to
    // define pre-proc. vars that add additional (usually obsolete) syscalls.
    //
    // TODO:
    // - It would be better to use libclang/translate-c directly to extract the definitions.
    // - The `-dD` option only does minimal pre-processing and doesn't resolve addition,
    //   so arch specific syscalls are dealt with manually.
    {
        try writer.writeAll("pub const Arm64 = enum(usize) {\n");

        const child_args = [_][]const u8{
            zig_exe,
            "cc",
            "-target",
            "aarch64-linux-gnu",
            "-E",
            // -dM is cleaner, but -dD preserves iteration order.
            "-dD",
            // No need for line-markers.
            "-P",
            "-nostdinc",
            // Using -I=[dir] includes the zig linux headers, which we don't want.
            "-Iinclude",
            "-Iinclude/uapi",
            "arch/arm64/include/uapi/asm/unistd.h",
        };

        const child_result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &child_args,
            .cwd = linux_path,
            .cwd_dir = linux_dir,
        });
        if (child_result.stderr.len > 0) std.debug.print("{s}\n", .{child_result.stderr});

        const defines = switch (child_result.term) {
            .Exited => |code| if (code == 0) child_result.stdout else {
                std.debug.print("zig cc exited with code {d}\n", .{code});
                std.process.exit(1);
            },
            else => {
                std.debug.print("zig cc crashed\n", .{});
                std.process.exit(1);
            },
        };

        var lines = mem.tokenizeScalar(u8, defines, '\n');
        loop: while (lines.next()) |line| {
            var fields = mem.tokenizeAny(u8, line, " \t");
            const cmd = fields.next() orelse return error.Incomplete;
            if (!mem.eql(u8, cmd, "#define")) continue;
            const define = fields.next() orelse return error.Incomplete;
            const number = fields.next() orelse continue;

            if (!std.ascii.isDigit(number[0])) continue;
            if (!mem.startsWith(u8, define, "__NR")) continue;
            const name = mem.trimLeft(u8, mem.trimLeft(u8, define, "__NR3264_"), "__NR_");
            if (mem.eql(u8, name, "arch_specific_syscall")) continue;
            if (mem.eql(u8, name, "syscalls")) break :loop;

            const fixed_name = if (stdlib_renames.get(name)) |fixed| fixed else name;
            try writer.print("    {p} = {s},\n", .{ zig.fmtId(fixed_name), number });
        }

        try writer.writeAll("};\n\n");
    }
    {
        try writer.writeAll(
            \\pub const RiscV64 = enum(usize) {
            \\    pub const arch_specific_syscall = 244;
            \\
            \\
        );

        const child_args = [_][]const u8{
            zig_exe,
            "cc",
            "-target",
            "riscv64-linux-gnu",
            "-E",
            "-dD",
            "-P",
            "-nostdinc",
            "-Iinclude",
            "-Iinclude/uapi",
            "arch/riscv/include/uapi/asm/unistd.h",
        };

        const child_result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &child_args,
            .cwd = linux_path,
            .cwd_dir = linux_dir,
        });
        if (child_result.stderr.len > 0) std.debug.print("{s}\n", .{child_result.stderr});

        const defines = switch (child_result.term) {
            .Exited => |code| if (code == 0) child_result.stdout else {
                std.debug.print("zig cc exited with code {d}\n", .{code});
                std.process.exit(1);
            },
            else => {
                std.debug.print("zig cc crashed\n", .{});
                std.process.exit(1);
            },
        };

        var lines = mem.tokenizeScalar(u8, defines, '\n');
        loop: while (lines.next()) |line| {
            var fields = mem.tokenizeAny(u8, line, " \t");
            const cmd = fields.next() orelse return error.Incomplete;
            if (!mem.eql(u8, cmd, "#define")) continue;
            const define = fields.next() orelse return error.Incomplete;
            const number = fields.next() orelse continue;

            if (!std.ascii.isDigit(number[0])) continue;
            if (!mem.startsWith(u8, define, "__NR")) continue;
            const name = mem.trimLeft(u8, mem.trimLeft(u8, define, "__NR3264_"), "__NR_");
            if (mem.eql(u8, name, "arch_specific_syscall")) continue;
            if (mem.eql(u8, name, "syscalls")) break :loop;

            const fixed_name = if (stdlib_renames.get(name)) |fixed| fixed else name;
            try writer.print("    {p} = {s},\n", .{ zig.fmtId(fixed_name), number });
        }

        try writer.writeAll(
            \\
            \\    riscv_flush_icache = arch_specific_syscall + 15,
            \\    riscv_hwprobe = arch_specific_syscall + 14,
            \\};
            \\
        );
    }
    {
        try writer.writeAll(
            \\
            \\pub const LoongArch64 = enum(usize) {
            \\
        );

        const child_args = [_][]const u8{
            zig_exe,
            "cc",
            "-march=loongarch64",
            "-target",
            "loongarch64-linux-gnu",
            "-E",
            "-dD",
            "-P",
            "-nostdinc",
            "-Iinclude",
            "-Iinclude/uapi",
            "arch/loongarch/include/uapi/asm/unistd.h",
        };

        const child_result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &child_args,
            .cwd = linux_path,
            .cwd_dir = linux_dir,
        });
        if (child_result.stderr.len > 0) std.debug.print("{s}\n", .{child_result.stderr});

        const defines = switch (child_result.term) {
            .Exited => |code| if (code == 0) child_result.stdout else {
                std.debug.print("zig cc exited with code {d}\n", .{code});
                std.process.exit(1);
            },
            else => {
                std.debug.print("zig cc crashed\n", .{});
                std.process.exit(1);
            },
        };

        var lines = mem.tokenizeScalar(u8, defines, '\n');
        loop: while (lines.next()) |line| {
            var fields = mem.tokenizeAny(u8, line, " \t");
            const cmd = fields.next() orelse return error.Incomplete;
            if (!mem.eql(u8, cmd, "#define")) continue;
            const define = fields.next() orelse return error.Incomplete;
            const number = fields.next() orelse continue;

            if (!std.ascii.isDigit(number[0])) continue;
            if (!mem.startsWith(u8, define, "__NR")) continue;
            const name = mem.trimLeft(u8, mem.trimLeft(u8, define, "__NR3264_"), "__NR_");
            if (mem.eql(u8, name, "arch_specific_syscall")) continue;
            if (mem.eql(u8, name, "syscalls")) break :loop;

            const fixed_name = if (stdlib_renames.get(name)) |fixed| fixed else name;
            try writer.print("    {p} = {s},\n", .{ zig.fmtId(fixed_name), number });
        }

        try writer.writeAll(
            \\};
            \\
        );
    }

    try buf_out.flush();
}

fn usageAndExit(file: fs.File, arg0: []const u8, code: u8) noreturn {
    file.writer().print(
        \\Usage: {s} /path/to/zig /path/to/linux
        \\Alternative Usage: zig run /path/to/git/zig/tools/generate_linux_syscalls.zig -- /path/to/zig /path/to/linux
        \\
        \\Generates the list of Linux syscalls for each supported cpu arch, using the Linux development tree.
        \\Prints to stdout Zig code which you can use to replace the file lib/std/os/linux/syscalls.zig.
        \\
    , .{arg0}) catch std.process.exit(1);
    std.process.exit(code);
}
