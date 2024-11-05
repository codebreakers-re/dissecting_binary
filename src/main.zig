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

    var index: u32 = 0;

    const path: []const u8 = blk: {
        while (args.next()) |arg| : (index += 1) {
            std.debug.print("Order {d} Args: {s} \n", .{ index, arg });
            if (index == 1) {
                break :blk arg;
            }
        }
        unreachable;
    };

    std.debug.print("{s} \n", .{path});

    const file = blk: {
        if (std.fs.path.isAbsolute(path)) {
            break :blk try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
        } else {
            break :blk try std.fs.cwd().openFile(path, .{ .mode = .read_only });
        }
    };

    defer file.close();

    const e_ident = try read_e_ident(file);

    assert(is_elf(e_ident));

    const res: ElfReader = blk: {
        switch (e_ident[elf.EI_CLASS]) {
            elf.ELFCLASS64 => {
                const bit64 = try ElfFile(elf.Elf64_Ehdr).init(file, allocator);
                break :blk ElfReader{ .bit64 = bit64 };
            },
            elf.ELFCLASS32 => {
                const bit32 = try ElfFile(elf.Elf32_Ehdr).init(file, allocator);
                break :blk ElfReader{ .bit32 = bit32 };
            },
            else => unreachable,
        }
    };

    defer res.free();

    res.print_header();
}

const ElfReader = union(enum) {
    bit32: ElfFile(elf.Elf32_Ehdr),
    bit64: ElfFile(elf.Elf64_Ehdr),

    pub fn free(self: ElfReader) void {
        switch (self) {
            inline else => |case| return case.free(),
        }
    }

    pub fn print_header(self: ElfReader) void {
        switch (self) {
            inline else => |case| return case.print_header(),
        }
    }
};

pub fn ElfFile(comptime T: type) type {
    const S: type = comptime switch (@typeName(T)) {
        @typeName(elf.Elf64_Ehdr) => elf.Elf64_Shdr,
        @typeName(elf.Elf32_Ehdr) => elf.Elf32_Shdr,
        else => unreachable,
    };
    const P: type = comptime switch (@typeName(T)) {
        @typeName(elf.Elf64_Ehdr) => elf.Elf64_Phdr,
        @typeName(elf.Elf32_Ehdr) => elf.Elf32_Phdr,
        else => unreachable,
    };

    const is64Bit = comptime (@typeName(T) == @typeName(elf.Elf64_Ehdr));

    return struct {
        header: T,
        sectionHeaders: []S,
        programHeaders: []P,
        file: std.fs.File,
        allocator: std.mem.Allocator,
        const Self = @This();

        pub fn init(file: std.fs.File, allocator: std.mem.Allocator) !Self {
            const e_ident: [16]u8 = try read_e_ident(file);

            assert(is_elf(e_ident));

            var header: T = undefined;

            if (is64Bit) {
                assert(e_ident[elf.EI_CLASS] == elf.ELFCLASS64);
                header = try readStruct(elf.Elf64_Ehdr, file, 0);
            } else {
                assert(e_ident[elf.EI_CLASS] == elf.ELFCLASS32);
                header = try readStruct(elf.Elf32_Ehdr, file, 0);
            }

            const sectionHeaders: []S = try readSequenceOfStruct(S, file, header.e_shoff, header.e_shnum, allocator);
            const programHeaders: []P = try readSequenceOfStruct(P, file, header.e_phoff, header.e_phnum, allocator);

            return .{ .header = header, .file = file, .allocator = allocator, .sectionHeaders = sectionHeaders, .programHeaders = programHeaders };
        }

        pub fn free(self: Self) void {
            self.allocator.free(self.sectionHeaders);
            self.allocator.free(self.programHeaders);
        }

        pub fn print_header(self: Self) void {
            const info = e_ident_info(self.header.e_ident);

            const et_type = getType(self.header.e_type);
            const machine = getMachine(self.header.e_machine);
            if (is64Bit) {
                // const header: elf.Elf64_Ehdr = self.header;
                // header.e_machine
            } else {
                // const header: elf.Elf32_Ehdr = self.header;
            }

            std.debug.print("This is an {s} Elf File, with {s} encoding of version: {s} \n", .{ info.class, info.endianness, info.elfVersion });
            std.debug.print("The is an {s} and runs on a {s} CPU \n", .{ et_type, machine });
        }

        fn e_ident_info(e_ident: [16]u8) struct { class: [*:0]const u8, endianness: [*:0]const u8, elfVersion: [*:0]const u8 } {
            const elfClass = switch (e_ident[elf.EI_CLASS]) {
                elf.ELFCLASSNONE => "None",
                elf.ELFCLASS32 => "32 Bit",
                elf.ELFCLASS64 => "64 Bit",
                else => unreachable,
            };

            const elfData = switch (e_ident[elf.EI_DATA]) {
                elf.ELFDATANONE => "None",
                elf.ELFDATA2LSB => "LSB",
                elf.ELFDATA2MSB => "MSB",
                else => unreachable,
            };

            const elfVersion = switch (e_ident[elf.EI_VERSION]) {
                elf.EV_CURRENT => "1",
                else => unreachable,
            };

            return .{ .class = elfClass, .endianness = elfData, .elfVersion = elfVersion };
        }
    };
}

pub fn is_elf(e_ident: [16]u8) bool {
    const magic_bytes = e_ident[0..4];

    const elf_array: [4]u8 = .{ 0x7f, 'E', 'L', 'F' };

    for (magic_bytes.*, elf_array) |magic, elf_byte| {
        if (magic != elf_byte) {
            return false;
        }
    }
    return true;
}

pub fn read_e_ident(elf_file: std.fs.File) ![16]u8 {
    var e_ident: [16]u8 = undefined;
    try elf_file.seekTo(0);

    const bytes_read = try elf_file.readAll(&e_ident);
    assert(bytes_read == 16);
    return e_ident;
}

pub fn readSequenceOfStruct(comptime T: type, elf_file: std.fs.File, initial_location: u64, items: u16, allocator: std.mem.Allocator) ![]T {
    const size = @sizeOf(T);
    var buffer: [size]u8 = undefined;
    const mem: []T = try allocator.alloc(T, items);

    for (0..items) |index| {
        try elf_file.seekTo(initial_location + index * size);
        const readBytes = try elf_file.readAll(&buffer);
        assert(readBytes == size);
        const elf_header: *T = @ptrCast(@alignCast(&buffer));

        mem[index] = elf_header.*;
    }
    return mem;
}

pub fn readStruct(comptime T: type, elf_file: std.fs.File, location: u64) !T {
    const size = @sizeOf(T);
    var buffer: [size]u8 = undefined;

    try elf_file.seekTo(location);
    const readBytes = try elf_file.readAll(&buffer);
    assert(readBytes == size);

    const elf_header: *T = @ptrCast(@alignCast(&buffer));
    return elf_header.*;
}

pub fn getType(e_type: u16) [*:0]const u8 {
    return switch (e_type) {
        elf.ET_NONE => "No file type",
        elf.ET_REL => "Relocatable file",
        elf.ET_EXEC => "Executable file",
        elf.ET_DYN => "Shared object file",
        elf.ET_CORE => "Core file",
        elf.ET_NUM => "Number of defined types",
        elf.ET_LOOS => "OS-specific range start",
        elf.ET_HIOS => "OS-specific range end",
        elf.ET_LOPROC => "Processor-specific range start",
        elf.ET_HIPROC => "Processor-specific range end",
        else => unreachable,
    };
}

pub fn getMachine(e_machine: u16) [*:0]const u8 {
    return switch (e_machine) {
        elf.EM_NONE => "NONE",
        elf.EM_M32 => "M32",
        elf.EM_SPARC => "SPARC",
        elf.EM_386 => "386",
        elf.EM_68K => "68K",
        elf.EM_88K => "88K",
        elf.EM_IAMCU => "IAMCU",
        elf.EM_860 => "860",
        elf.EM_MIPS => "MIPS",
        elf.EM_S370 => "S370",
        elf.EM_MIPS_RS3_LE => "MIPS_RS3_LE",
        elf.EM_PARISC => "PARISC",
        elf.EM_VPP500 => "VPP500",
        elf.EM_SPARC32PLUS => "SPARC32PLUS",
        elf.EM_960 => "960",
        elf.EM_PPC => "PPC",
        elf.EM_PPC64 => "PPC64",
        elf.EM_S390 => "S390",
        elf.EM_SPU => "SPU",
        elf.EM_V800 => "V800",
        elf.EM_FR20 => "FR20",
        elf.EM_RH32 => "RH32",
        elf.EM_RCE => "RCE",
        elf.EM_ARM => "ARM",
        elf.EM_FAKE_ALPHA => "FAKE_ALPHA",
        elf.EM_SH => "SH",
        elf.EM_SPARCV9 => "SPARCV9",
        elf.EM_TRICORE => "TRICORE",
        elf.EM_ARC => "ARC",
        elf.EM_H8_300 => "H8_300",
        elf.EM_H8_300H => "H8_300H",
        elf.EM_H8S => "H8S",
        elf.EM_H8_500 => "H8_500",
        elf.EM_IA_64 => "IA_64",
        elf.EM_MIPS_X => "MIPS_X",
        elf.EM_COLDFIRE => "COLDFIRE",
        elf.EM_68HC12 => "68HC12",
        elf.EM_MMA => "MMA",
        elf.EM_PCP => "PCP",
        elf.EM_NCPU => "NCPU",
        elf.EM_NDR1 => "NDR1",
        elf.EM_STARCORE => "STARCORE",
        elf.EM_ME16 => "ME16",
        elf.EM_ST100 => "ST100",
        elf.EM_TINYJ => "TINYJ",
        elf.EM_X86_64 => "X86_64",
        elf.EM_PDSP => "PDSP",
        elf.EM_PDP10 => "PDP10",
        elf.EM_PDP11 => "PDP11",
        elf.EM_FX66 => "FX66",
        elf.EM_ST9PLUS => "ST9PLUS",
        elf.EM_ST7 => "ST7",
        elf.EM_68HC16 => "68HC16",
        elf.EM_68HC11 => "68HC11",
        elf.EM_68HC08 => "68HC08",
        elf.EM_68HC05 => "68HC05",
        elf.EM_SVX => "SVX",
        elf.EM_ST19 => "ST19",
        elf.EM_VAX => "VAX",
        elf.EM_CRIS => "CRIS",
        elf.EM_JAVELIN => "JAVELIN",
        elf.EM_FIREPATH => "FIREPATH",
        elf.EM_ZSP => "ZSP",
        elf.EM_MMIX => "MMIX",
        elf.EM_HUANY => "HUANY",
        elf.EM_PRISM => "PRISM",
        elf.EM_AVR => "AVR",
        elf.EM_FR30 => "FR30",
        elf.EM_D10V => "D10V",
        elf.EM_D30V => "D30V",
        elf.EM_V850 => "V850",
        elf.EM_M32R => "M32R",
        elf.EM_MN10300 => "MN10300",
        elf.EM_MN10200 => "MN10200",
        elf.EM_PJ => "PJ",
        elf.EM_OPENRISC => "OPENRISC",
        elf.EM_XTENSA => "XTENSA",
        elf.EM_VIDEOCORE => "VIDEOCORE",
        elf.EM_TMM_GPP => "TMM_GPP",
        elf.EM_NS32K => "NS32K",
        elf.EM_TPC => "TPC",
        elf.EM_SNP1K => "SNP1K",
        elf.EM_ST200 => "ST200",
        elf.EM_IP2K => "IP2K",
        elf.EM_MAX => "MAX",
        elf.EM_CR => "CR",
        elf.EM_F2MC16 => "F2MC16",
        elf.EM_MSP430 => "MSP430",
        elf.EM_BLACKFIN => "BLACKFIN",
        elf.EM_SE_C33 => "SE_C33",
        elf.EM_SEP => "SEP",
        elf.EM_ARCA => "ARCA",
        elf.EM_UNICORE => "UNICORE",
        elf.EM_EXCESS => "EXCESS",
        elf.EM_DXP => "DXP",
        elf.EM_ALTERA_NIOS2 => "ALTERA_NIOS2",
        elf.EM_CRX => "CRX",
        elf.EM_XGATE => "XGATE",
        elf.EM_C166 => "C166",
        elf.EM_M16C => "M16C",
        elf.EM_DSPIC30F => "DSPIC30F",
        elf.EM_CE => "CE",
        elf.EM_M32C => "M32C",
        elf.EM_TSK3000 => "TSK3000",
        elf.EM_RS08 => "RS08",
        elf.EM_SHARC => "SHARC",
        elf.EM_ECOG2 => "ECOG2",
        elf.EM_SCORE7 => "SCORE7",
        elf.EM_DSP24 => "DSP24",
        elf.EM_VIDEOCORE3 => "VIDEOCORE3",
        elf.EM_LATTICEMICO32 => "LATTICEMICO32",
        elf.EM_SE_C17 => "SE_C17",
        elf.EM_TI_C6000 => "TI_C6000",
        elf.EM_TI_C2000 => "TI_C2000",
        elf.EM_TI_C5500 => "TI_C5500",
        elf.EM_TI_ARP32 => "TI_ARP32",
        elf.EM_TI_PRU => "TI_PRU",
        elf.EM_MMDSP_PLUS => "MMDSP_PLUS",
        elf.EM_CYPRESS_M8C => "CYPRESS_M8C",
        elf.EM_R32C => "R32C",
        elf.EM_TRIMEDIA => "TRIMEDIA",
        elf.EM_QDSP6 => "QDSP6",
        elf.EM_8051 => "8051",
        elf.EM_STXP7X => "STXP7X",
        elf.EM_NDS32 => "NDS32",
        elf.EM_ECOG1X => "ECOG1X",
        elf.EM_MAXQ30 => "MAXQ30",
        elf.EM_XIMO16 => "XIMO16",
        elf.EM_MANIK => "MANIK",
        elf.EM_CRAYNV2 => "CRAYNV2",
        elf.EM_RX => "RX",
        elf.EM_METAG => "METAG",
        elf.EM_MCST_ELBRUS => "MCST_ELBRUS",
        elf.EM_ECOG16 => "ECOG16",
        elf.EM_CR16 => "CR16",
        elf.EM_ETPU => "ETPU",
        elf.EM_SLE9X => "SLE9X",
        elf.EM_L10M => "L10M",
        elf.EM_K10M => "K10M",
        elf.EM_AARCH64 => "AARCH64",
        elf.EM_AVR32 => "AVR32",
        elf.EM_STM8 => "STM8",
        elf.EM_TILE64 => "TILE64",
        elf.EM_TILEPRO => "TILEPRO",
        elf.EM_MICROBLAZE => "MICROBLAZE",
        elf.EM_CUDA => "CUDA",
        elf.EM_TILEGX => "TILEGX",
        elf.EM_CLOUDSHIELD => "CLOUDSHIELD",
        elf.EM_COREA_1ST => "COREA_1ST",
        elf.EM_COREA_2ND => "COREA_2ND",
        elf.EM_ARCV2 => "ARCV2",
        elf.EM_OPEN8 => "OPEN8",
        elf.EM_RL78 => "RL78",
        elf.EM_VIDEOCORE5 => "VIDEOCORE5",
        elf.EM_78KOR => "78KOR",
        elf.EM_56800EX => "56800EX",
        elf.EM_BA1 => "BA1",
        elf.EM_BA2 => "BA2",
        elf.EM_XCORE => "XCORE",
        elf.EM_MCHP_PIC => "MCHP_PIC",
        elf.EM_INTELGT => "INTELGT",
        elf.EM_KM32 => "KM32",
        elf.EM_KMX32 => "KMX32",
        elf.EM_EMX16 => "EMX16",
        elf.EM_EMX8 => "EMX8",
        elf.EM_KVARC => "KVARC",
        elf.EM_CDP => "CDP",
        elf.EM_COGE => "COGE",
        elf.EM_COOL => "COOL",
        elf.EM_NORC => "NORC",
        elf.EM_CSR_KALIMBA => "CSR_KALIMBA",
        elf.EM_Z80 => "Z80",
        elf.EM_VISIUM => "VISIUM",
        elf.EM_FT32 => "FT32",
        elf.EM_MOXIE => "MOXIE",
        elf.EM_AMDGPU => "AMDGPU",
        elf.EM_RISCV => "RISCV",
        elf.EM_BPF => "BPF",
        elf.EM_CSKY => "CSKY",
        elf.EM_NUM => "NUM",
        elf.EM_ARC_A5 => "ARC_A5",
        elf.EM_ALPHA => "ALPHA",
        else => unreachable,
    };
}
