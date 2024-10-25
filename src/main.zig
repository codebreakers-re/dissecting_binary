const std = @import("std");
const expect = std.testing.expect;
const assert = std.debug.assert;

const elf = @cImport({
    @cInclude("elf.h");
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("Leakded memory from GPA");
    }

    var args = try std.process.argsWithAllocator(allocator);
    var path: []const u8 = undefined;

    var index: u32 = 0;

    while (args.next()) |arg| : (index += 1) {
        std.debug.print("Order {d} Args: {s} \n", .{ index, arg });
        if (index == 1) {
            path = arg;
        }
    }

    std.debug.print("{s} \n", .{path});

    const file = try (if (std.fs.path.isAbsolute(path)) std.fs.openFileAbsolute(path, .{ .mode = .read_only }) else std.fs.cwd().openFile(path, .{ .mode = .read_only }));
    defer file.close();

    var e_ident: [16]u8 = undefined;
    //
    const bytes_read = try file.readAll(&e_ident);

    std.debug.print("read bytes {d} content : {x} \n", .{ bytes_read, e_ident });

    const magic_bytes = e_ident[0..4];
    const elf_array: [4]u8 = .{ 0x7f, 'E', 'L', 'F' };

    assert(magic_bytes.len == elf_array.len);

    for (magic_bytes.*, elf_array) |magic, elf_byte| {
        if (magic != elf_byte) {
            unreachable;
        }
    }

    const elfClass = switch (e_ident[elf.EI_CLASS]) {
        elf.ELFCLASSNONE => "None",
        elf.ELFCLASS32 => "32 Bit",
        elf.ELFCLASS64 => "64 Bit",
        else => unreachable,
    };

    std.debug.print("Found an {s} ELF File \n", .{elfClass});

    const elfData = switch (e_ident[elf.EI_DATA]) {
        elf.ELFDATANONE => "None",
        elf.ELFDATA2LSB => "Little endian",
        elf.ELFDATA2MSB => "Big Endian",
        else => unreachable,
    };

    std.debug.print("ELF encoding is {s} \n", .{elfData});

    const elfVersion = switch (e_ident[elf.EI_VERSION]) {
        elf.EV_CURRENT => "Version 1",
        else => unreachable,
    };

    std.debug.print("ELF version is {s} \n", .{elfVersion});
    const padding_bytes = elf.EI_VERSION + 1;

    for (e_ident[padding_bytes..]) |b| {
        if (b != 0x0) unreachable;
    }
}

// if (e_ident[elf.EI_CLASS] == elf.ELFCLASS64) {
//     std.debug.print("64 bit elf header size: {d}\n", .{@sizeOf(elf.Elf64_Ehdr)});
//     const header = try readHeader(elf.Elf64_Ehdr, file);
//     std.debug.print("{x} \n", .{header.e_ident});
// } else if (e_ident[elf.EI_CLASS] == elf.ELFCLASS32) {
//     std.debug.print("32 bit elf header size: {d}\n", .{@sizeOf(elf.Elf32_Ehdr)});
//     const header = try readHeader(elf.Elf32_Ehdr, file);
//     std.debug.print("{x} \n", .{header.e_ident});
// }
//
// pub fn readHeader(comptime T: type, elf_file: std.fs.File) !T {
//     const size = @sizeOf(T);
//     var buffer: [size]u8 = undefined;
//
//     try elf_file.seekTo(0);
//     const readBytes = try elf_file.readAll(&buffer);
//     assert(readBytes == size);
//
//     const elf_header: *T = @ptrCast(@alignCast(&buffer));
//     return elf_header.*;
// }
