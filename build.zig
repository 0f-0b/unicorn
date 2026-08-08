const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Arch = enum {
    x86,
    arm,
    aarch64,
    m68k,
    mips,
    sparc,
    ppc,
    riscv,
    s390x,
    tricore,
};

fn makeUnicornCFlags(arena: Allocator, archs: std.EnumSet(Arch)) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try list.append(arena, "-fno-sanitize=function");
    var it = archs.iterator();
    while (it.next()) |arch| {
        switch (arch) {
            .x86 => try list.append(arena, "-DUNICORN_HAS_X86"),
            .arm => try list.append(arena, "-DUNICORN_HAS_ARM"),
            .aarch64 => try list.append(arena, "-DUNICORN_HAS_ARM64"),
            .m68k => try list.append(arena, "-DUNICORN_HAS_M68K"),
            .mips => try list.appendSlice(arena, &.{
                "-DUNICORN_HAS_MIPS",
                "-DUNICORN_HAS_MIPSEL",
                "-DUNICORN_HAS_MIPS64",
                "-DUNICORN_HAS_MIPS64EL",
            }),
            .sparc => try list.append(arena, "-DUNICORN_HAS_SPARC"),
            .ppc => try list.append(arena, "-DUNICORN_HAS_PPC"),
            .riscv => try list.append(arena, "-DUNICORN_HAS_RISCV"),
            .s390x => try list.append(arena, "-DUNICORN_HAS_S390X"),
            .tricore => try list.append(arena, "-DUNICORN_HAS_TRICORE"),
        }
    }
    return list.items;
}

const HostConfig = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    lto: std.zig.LtoMode,
    config_header: *std.Build.Step.ConfigHeader,
    include_paths: []const std.Build.LazyPath,
};

const TargetConfig = struct {
    name: []const u8,
    files: []const []const u8,
    include_paths: []const []const u8,
    autogen_header_contents: []const u8,
};

fn createTargetLibrary(
    b: *std.Build,
    host: HostConfig,
    comptime target: TargetConfig,
    comptime defines: anytype,
) *std.Build.Step.Compile {
    const config_target = b.addConfigHeader(.{ .include_path = "config-target.h" }, defines);
    const mod = b.createModule(.{
        .target = host.target,
        .optimize = host.optimize,
        .link_libc = true,
    });
    mod.addConfigHeader(host.config_header);
    mod.addConfigHeader(config_target);
    for (host.include_paths) |path| mod.addIncludePath(path);
    for (target.include_paths) |path| mod.addIncludePath(b.path(path));
    var it = std.mem.splitScalar(u8, target.autogen_header_contents, '\n');
    while (it.next()) |line| {
        const define = std.mem.cutPrefix(u8, line, "#define ") orelse continue;
        const key, const value = std.mem.cutScalar(u8, define, ' ') orelse .{ define, "" };
        mod.addCMacro(key, value);
    }
    mod.addCSourceFiles(.{
        .root = b.path(""),
        .files = .{
            "qemu/exec.c",
            "qemu/exec-vary.c",
            "qemu/softmmu/cpus.c",
            "qemu/softmmu/ioport.c",
            "qemu/softmmu/memory.c",
            "qemu/softmmu/memory_mapping.c",
            "qemu/fpu/softfloat.c",
            "qemu/tcg/optimize.c",
            "qemu/tcg/tcg.c",
            "qemu/tcg/tcg-op.c",
            "qemu/tcg/tcg-op-gvec.c",
            "qemu/tcg/tcg-op-vec.c",
            "qemu/accel/tcg/cpu-exec.c",
            "qemu/accel/tcg/cpu-exec-common.c",
            "qemu/accel/tcg/cputlb.c",
            "qemu/accel/tcg/tcg-all.c",
            "qemu/accel/tcg/tcg-runtime.c",
            "qemu/accel/tcg/tcg-runtime-gvec.c",
            "qemu/accel/tcg/translate-all.c",
            "qemu/accel/tcg/translator.c",
            "qemu/softmmu/unicorn_vtlb.c",
        } ++ target.files,
        .flags = &.{ "-fno-sanitize=function", "-DNEED_CPU_H" },
    });
    const lib = b.addLibrary(.{
        .name = target.name,
        .root_module = mod,
    });
    lib.lto = host.lto;
    return lib;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lto = b.option(std.zig.LtoMode, "lto", "Link-time optimization mode") orelse .none;
    var archs: std.EnumSet(Arch) = .empty;
    if (b.option([]const Arch, "arch", "Enabled unicorn architectures")) |list| {
        for (list) |i| archs.insert(i);
    } else {
        archs = .full;
    }

    const arena = b.graph.arena;
    const cflags = try makeUnicornCFlags(arena, archs);

    const tcg_target = switch (target.result.cpu.arch) {
        .x86, .x86_64 => "i386",
        .arm, .armeb, .thumb, .thumbeb => "arm",
        .aarch64, .aarch64_be => "aarch64",
        .mips, .mipsel, .mips64, .mips64el => "mips",
        .sparc, .sparc64 => "sparc",
        .powerpc, .powerpcle, .powerpc64, .powerpc64le => "ppc",
        .riscv32, .riscv32be, .riscv64, .riscv64be => "riscv",
        .s390x => "s390",
        .loongarch64 => "loongarch64",
        else => return error.UnsupportedTarget,
    };

    const is_macos = target.result.os.tag == .macos;
    const is_windows = target.result.os.tag == .windows;
    const endian = target.result.cpu.arch.endian();

    const host: HostConfig = .{
        .target = target,
        .optimize = optimize,
        .lto = lto,
        .config_header = b.addConfigHeader(.{ .include_path = "config-host.h" }, .{
            .CONFIG_CMPXCHG128 = true,
            .CONFIG_INT128 = true,
            .CONFIG_MADVISE = if (is_windows) null else true,
            .CONFIG_POSIX = if (is_windows) null else true,
            .CONFIG_POSIX_MEMALIGN = if (is_windows) null else true,
            .CONFIG_PRAGMA_DIAGNOSTIC_AVAILABLE = true,
            .CONFIG_STATIC_ASSERT = true,
            .HAVE_PTHREAD_JIT_PROTECT = if (is_macos) true else null,
            .HOST_WORDS_BIGENDIAN = if (endian == .big) true else null,
        }),
        .include_paths = &.{
            b.path("glib_compat"),
            b.path("qemu"),
            b.path("qemu/include"),
            b.path("qemu/tcg").path(b, tcg_target),
            b.path("include"),
        },
    };

    const libunicorn_common = unicorn_common: {
        const mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mod.addConfigHeader(host.config_header);
        for (host.include_paths) |path| mod.addIncludePath(path);
        mod.addCSourceFiles(.{
            .root = b.path(""),
            .files = &(.{
                "list.c",
                "glib_compat/glib_compat.c",
                "glib_compat/gtestutils.c",
                "glib_compat/garray.c",
                "glib_compat/gtree.c",
                "glib_compat/grand.c",
                "glib_compat/glist.c",
                "glib_compat/gmem.c",
                "glib_compat/gpattern.c",
                "glib_compat/gslice.c",
                "qemu/util/bitmap.c",
                "qemu/util/bitops.c",
                "qemu/util/crc32c.c",
                "qemu/util/cutils.c",
                "qemu/util/getauxval.c",
                "qemu/util/guest-random.c",
                "qemu/util/host-utils.c",
                "qemu/util/osdep.c",
                "qemu/util/qdist.c",
                "qemu/util/qemu-timer.c",
                "qemu/util/qemu-timer-common.c",
                "qemu/util/range.c",
                "qemu/util/qht.c",
                "qemu/util/pagesize.c",
                "qemu/util/cacheinfo.c",
                "qemu/crypto/aes.c",
            } ++ if (is_windows and !target.result.abi.isGnu()) .{
                "qemu/util/oslib-win32.c",
                "qemu/util/qemu-thread-win32.c",
            } else .{
                "qemu/util/oslib-posix.c",
                "qemu/util/qemu-thread-posix.c",
            }),
            .flags = cflags,
        });
        const lib = b.addLibrary(.{
            .name = "unicorn-common",
            .root_module = mod,
        });
        lib.lto = lto;
        break :unicorn_common lib;
    };

    const libx86_64_softmmu = createTargetLibrary(b, host, .{
        .name = "x86_64-softmmu",
        .files = &.{
            "qemu/hw/i386/x86.c",
            "qemu/target/i386/arch_memory_mapping.c",
            "qemu/target/i386/bpt_helper.c",
            "qemu/target/i386/cc_helper.c",
            "qemu/target/i386/cpu.c",
            "qemu/target/i386/excp_helper.c",
            "qemu/target/i386/fpu_helper.c",
            "qemu/target/i386/helper.c",
            "qemu/target/i386/int_helper.c",
            "qemu/target/i386/machine.c",
            "qemu/target/i386/mem_helper.c",
            "qemu/target/i386/misc_helper.c",
            "qemu/target/i386/mpx_helper.c",
            "qemu/target/i386/seg_helper.c",
            "qemu/target/i386/smm_helper.c",
            "qemu/target/i386/svm_helper.c",
            "qemu/target/i386/translate.c",
            "qemu/target/i386/xsave_helper.c",
            "qemu/target/i386/unicorn.c",
        },
        .include_paths = &.{"qemu/target/i386"},
        .autogen_header_contents = @embedFile("qemu/x86_64.h"),
    }, .{
        .CONFIG_SOFTMMU = true,
        .TARGET_I386 = true,
        .TARGET_X86_64 = true,
    });

    const libarm_softmmu = createTargetLibrary(b, host, .{
        .name = "arm-softmmu",
        .files = &.{
            "qemu/target/arm/cpu.c",
            "qemu/target/arm/crypto_helper.c",
            "qemu/target/arm/debug_helper.c",
            "qemu/target/arm/helper.c",
            "qemu/target/arm/iwmmxt_helper.c",
            "qemu/target/arm/m_helper.c",
            "qemu/target/arm/neon_helper.c",
            "qemu/target/arm/op_helper.c",
            "qemu/target/arm/psci.c",
            "qemu/target/arm/tlb_helper.c",
            "qemu/target/arm/translate.c",
            "qemu/target/arm/vec_helper.c",
            "qemu/target/arm/vfp_helper.c",
            "qemu/target/arm/unicorn_arm.c",
        },
        .include_paths = &.{"qemu/target/arm"},
        .autogen_header_contents = @embedFile("qemu/arm.h"),
    }, .{
        .CONFIG_SOFTMMU = true,
        .TARGET_ARM = true,
    });

    const libaarch64_softmmu = createTargetLibrary(b, host, .{
        .name = "aarch64-softmmu",
        .files = &.{
            "qemu/target/arm/cpu64.c",
            "qemu/target/arm/cpu.c",
            "qemu/target/arm/crypto_helper.c",
            "qemu/target/arm/debug_helper.c",
            "qemu/target/arm/helper-a64.c",
            "qemu/target/arm/helper.c",
            "qemu/target/arm/iwmmxt_helper.c",
            "qemu/target/arm/m_helper.c",
            "qemu/target/arm/neon_helper.c",
            "qemu/target/arm/op_helper.c",
            "qemu/target/arm/pauth_helper.c",
            "qemu/target/arm/psci.c",
            "qemu/target/arm/sve_helper.c",
            "qemu/target/arm/tlb_helper.c",
            "qemu/target/arm/translate-a64.c",
            "qemu/target/arm/translate.c",
            "qemu/target/arm/translate-sve.c",
            "qemu/target/arm/vec_helper.c",
            "qemu/target/arm/vfp_helper.c",
            "qemu/target/arm/unicorn_aarch64.c",
        },
        .include_paths = &.{"qemu/target/arm"},
        .autogen_header_contents = @embedFile("qemu/aarch64.h"),
    }, .{
        .CONFIG_SOFTMMU = true,
        .TARGET_AARCH64 = true,
        .TARGET_ARM = true,
    });

    const libm68k_softmmu = createTargetLibrary(b, host, .{
        .name = "m68k-softmmu",
        .files = &.{
            "qemu/target/m68k/cpu.c",
            "qemu/target/m68k/fpu_helper.c",
            "qemu/target/m68k/helper.c",
            "qemu/target/m68k/op_helper.c",
            "qemu/target/m68k/softfloat.c",
            "qemu/target/m68k/translate.c",
            "qemu/target/m68k/unicorn.c",
        },
        .include_paths = &.{"qemu/target/m68k"},
        .autogen_header_contents = @embedFile("qemu/m68k.h"),
    }, .{
        .CONFIG_SOFTMMU = true,
        .TARGET_M68K = true,
        .TARGET_WORDS_BIGENDIAN = true,
    });

    const libmips_softmmu = createTargetLibrary(b, host, .{
        .name = "mips-softmmu",
        .files = &.{
            "qemu/target/mips/cp0_helper.c",
            "qemu/target/mips/cp0_timer.c",
            "qemu/target/mips/cpu.c",
            "qemu/target/mips/dsp_helper.c",
            "qemu/target/mips/fpu_helper.c",
            "qemu/target/mips/helper.c",
            "qemu/target/mips/lmi_helper.c",
            "qemu/target/mips/msa_helper.c",
            "qemu/target/mips/op_helper.c",
            "qemu/target/mips/translate.c",
            "qemu/target/mips/unicorn.c",
        },
        .include_paths = &.{"qemu/target/mips"},
        .autogen_header_contents = @embedFile("qemu/mips.h"),
    }, .{
        .CONFIG_SOFTMMU = true,
        .TARGET_ALIGNED_ONLY = true,
        .TARGET_MIPS = true,
        .TARGET_WORDS_BIGENDIAN = true,
    });

    const libmipsel_softmmu = createTargetLibrary(b, host, .{
        .name = "mipsel-softmmu",
        .files = &.{
            "qemu/target/mips/cp0_helper.c",
            "qemu/target/mips/cp0_timer.c",
            "qemu/target/mips/cpu.c",
            "qemu/target/mips/dsp_helper.c",
            "qemu/target/mips/fpu_helper.c",
            "qemu/target/mips/helper.c",
            "qemu/target/mips/lmi_helper.c",
            "qemu/target/mips/msa_helper.c",
            "qemu/target/mips/op_helper.c",
            "qemu/target/mips/translate.c",
            "qemu/target/mips/unicorn.c",
        },
        .include_paths = &.{"qemu/target/mips"},
        .autogen_header_contents = @embedFile("qemu/mipsel.h"),
    }, .{
        .CONFIG_SOFTMMU = true,
        .TARGET_ALIGNED_ONLY = true,
        .TARGET_MIPS = true,
    });

    const libmips64_softmmu = createTargetLibrary(b, host, .{
        .name = "mips64-softmmu",
        .files = &.{
            "qemu/target/mips/cp0_helper.c",
            "qemu/target/mips/cp0_timer.c",
            "qemu/target/mips/cpu.c",
            "qemu/target/mips/dsp_helper.c",
            "qemu/target/mips/fpu_helper.c",
            "qemu/target/mips/helper.c",
            "qemu/target/mips/lmi_helper.c",
            "qemu/target/mips/msa_helper.c",
            "qemu/target/mips/op_helper.c",
            "qemu/target/mips/translate.c",
            "qemu/target/mips/unicorn.c",
        },
        .include_paths = &.{"qemu/target/mips"},
        .autogen_header_contents = @embedFile("qemu/mips64.h"),
    }, .{
        .CONFIG_SOFTMMU = true,
        .TARGET_ALIGNED_ONLY = true,
        .TARGET_MIPS = true,
        .TARGET_MIPS64 = true,
        .TARGET_WORDS_BIGENDIAN = true,
    });

    const libmips64el_softmmu = createTargetLibrary(b, host, .{
        .name = "mips64el-softmmu",
        .files = &.{
            "qemu/target/mips/cp0_helper.c",
            "qemu/target/mips/cp0_timer.c",
            "qemu/target/mips/cpu.c",
            "qemu/target/mips/dsp_helper.c",
            "qemu/target/mips/fpu_helper.c",
            "qemu/target/mips/helper.c",
            "qemu/target/mips/lmi_helper.c",
            "qemu/target/mips/msa_helper.c",
            "qemu/target/mips/op_helper.c",
            "qemu/target/mips/translate.c",
            "qemu/target/mips/unicorn.c",
        },
        .include_paths = &.{"qemu/target/mips"},
        .autogen_header_contents = @embedFile("qemu/mips64el.h"),
    }, .{
        .CONFIG_SOFTMMU = true,
        .TARGET_ALIGNED_ONLY = true,
        .TARGET_MIPS = true,
        .TARGET_MIPS64 = true,
    });

    const libsparc_softmmu = createTargetLibrary(b, host, .{
        .name = "sparc-softmmu",
        .files = &.{
            "qemu/target/sparc/cc_helper.c",
            "qemu/target/sparc/cpu.c",
            "qemu/target/sparc/fop_helper.c",
            "qemu/target/sparc/helper.c",
            "qemu/target/sparc/int32_helper.c",
            "qemu/target/sparc/ldst_helper.c",
            "qemu/target/sparc/mmu_helper.c",
            "qemu/target/sparc/translate.c",
            "qemu/target/sparc/win_helper.c",
            "qemu/target/sparc/unicorn.c",
        },
        .include_paths = &.{"qemu/target/sparc"},
        .autogen_header_contents = @embedFile("qemu/sparc.h"),
    }, .{
        .CONFIG_SOFTMMU = true,
        .TARGET_ALIGNED_ONLY = true,
        .TARGET_SPARC = true,
        .TARGET_WORDS_BIGENDIAN = true,
    });

    const libsparc64_softmmu = createTargetLibrary(b, host, .{
        .name = "sparc64-softmmu",
        .files = &.{
            "qemu/target/sparc/cc_helper.c",
            "qemu/target/sparc/cpu.c",
            "qemu/target/sparc/fop_helper.c",
            "qemu/target/sparc/helper.c",
            "qemu/target/sparc/int64_helper.c",
            "qemu/target/sparc/ldst_helper.c",
            "qemu/target/sparc/mmu_helper.c",
            "qemu/target/sparc/translate.c",
            "qemu/target/sparc/vis_helper.c",
            "qemu/target/sparc/win_helper.c",
            "qemu/target/sparc/unicorn64.c",
        },
        .include_paths = &.{"qemu/target/sparc"},
        .autogen_header_contents = @embedFile("qemu/sparc64.h"),
    }, .{
        .CONFIG_SOFTMMU = true,
        .TARGET_ALIGNED_ONLY = true,
        .TARGET_SPARC = true,
        .TARGET_SPARC64 = true,
        .TARGET_WORDS_BIGENDIAN = true,
    });

    const libppc_softmmu = createTargetLibrary(b, host, .{
        .name = "ppc-softmmu",
        .files = &.{
            "qemu/hw/ppc/ppc.c",
            "qemu/hw/ppc/ppc_booke.c",
            "qemu/libdecnumber/decContext.c",
            "qemu/libdecnumber/decNumber.c",
            "qemu/libdecnumber/dpd/decimal128.c",
            "qemu/libdecnumber/dpd/decimal32.c",
            "qemu/libdecnumber/dpd/decimal64.c",
            "qemu/target/ppc/cpu.c",
            "qemu/target/ppc/cpu-models.c",
            "qemu/target/ppc/dfp_helper.c",
            "qemu/target/ppc/excp_helper.c",
            "qemu/target/ppc/fpu_helper.c",
            "qemu/target/ppc/int_helper.c",
            "qemu/target/ppc/machine.c",
            "qemu/target/ppc/mem_helper.c",
            "qemu/target/ppc/misc_helper.c",
            "qemu/target/ppc/mmu-hash32.c",
            "qemu/target/ppc/mmu_helper.c",
            "qemu/target/ppc/timebase_helper.c",
            "qemu/target/ppc/translate.c",
            "qemu/target/ppc/unicorn.c",
        },
        .include_paths = &.{"qemu/target/ppc"},
        .autogen_header_contents = @embedFile("qemu/ppc.h"),
    }, .{
        .CONFIG_SOFTMMU = true,
        .TARGET_PPC = true,
        .TARGET_WORDS_BIGENDIAN = true,
    });

    const libppc64_softmmu = createTargetLibrary(b, host, .{
        .name = "ppc64-softmmu",
        .files = &.{
            "qemu/hw/ppc/ppc.c",
            "qemu/hw/ppc/ppc_booke.c",
            "qemu/libdecnumber/decContext.c",
            "qemu/libdecnumber/decNumber.c",
            "qemu/libdecnumber/dpd/decimal128.c",
            "qemu/libdecnumber/dpd/decimal32.c",
            "qemu/libdecnumber/dpd/decimal64.c",
            "qemu/target/ppc/compat.c",
            "qemu/target/ppc/cpu.c",
            "qemu/target/ppc/cpu-models.c",
            "qemu/target/ppc/dfp_helper.c",
            "qemu/target/ppc/excp_helper.c",
            "qemu/target/ppc/fpu_helper.c",
            "qemu/target/ppc/int_helper.c",
            "qemu/target/ppc/machine.c",
            "qemu/target/ppc/mem_helper.c",
            "qemu/target/ppc/misc_helper.c",
            "qemu/target/ppc/mmu-book3s-v3.c",
            "qemu/target/ppc/mmu-hash32.c",
            "qemu/target/ppc/mmu-hash64.c",
            "qemu/target/ppc/mmu_helper.c",
            "qemu/target/ppc/mmu-radix64.c",
            "qemu/target/ppc/timebase_helper.c",
            "qemu/target/ppc/translate.c",
            "qemu/target/ppc/unicorn.c",
        },
        .include_paths = &.{"qemu/target/ppc"},
        .autogen_header_contents = @embedFile("qemu/ppc64.h"),
    }, .{
        .CONFIG_SOFTMMU = true,
        .TARGET_PPC = true,
        .TARGET_PPC64 = true,
        .TARGET_WORDS_BIGENDIAN = true,
    });

    const libriscv32_softmmu = createTargetLibrary(b, host, .{
        .name = "riscv32-softmmu",
        .files = &.{
            "qemu/target/riscv/cpu.c",
            "qemu/target/riscv/cpu_helper.c",
            "qemu/target/riscv/csr.c",
            "qemu/target/riscv/fpu_helper.c",
            "qemu/target/riscv/op_helper.c",
            "qemu/target/riscv/pmp.c",
            "qemu/target/riscv/translate.c",
            "qemu/target/riscv/unicorn.c",
        },
        .include_paths = &.{"qemu/target/riscv"},
        .autogen_header_contents = @embedFile("qemu/riscv32.h"),
    }, .{
        .CONFIG_SOFTMMU = true,
        .TARGET_RISCV = true,
        .TARGET_RISCV32 = true,
    });

    const libriscv64_softmmu = createTargetLibrary(b, host, .{
        .name = "riscv64-softmmu",
        .files = &.{
            "qemu/target/riscv/cpu.c",
            "qemu/target/riscv/cpu_helper.c",
            "qemu/target/riscv/csr.c",
            "qemu/target/riscv/fpu_helper.c",
            "qemu/target/riscv/op_helper.c",
            "qemu/target/riscv/pmp.c",
            "qemu/target/riscv/translate.c",
            "qemu/target/riscv/unicorn.c",
        },
        .include_paths = &.{"qemu/target/riscv"},
        .autogen_header_contents = @embedFile("qemu/riscv64.h"),
    }, .{
        .CONFIG_SOFTMMU = true,
        .TARGET_RISCV = true,
        .TARGET_RISCV64 = true,
    });

    const libs390x_softmmu = createTargetLibrary(b, host, .{
        .name = "s390x-softmmu",
        .files = &.{
            "qemu/hw/s390x/s390-skeys.c",
            "qemu/target/s390x/cc_helper.c",
            "qemu/target/s390x/cpu.c",
            "qemu/target/s390x/cpu_features.c",
            "qemu/target/s390x/cpu_models.c",
            "qemu/target/s390x/crypto_helper.c",
            "qemu/target/s390x/excp_helper.c",
            "qemu/target/s390x/fpu_helper.c",
            "qemu/target/s390x/helper.c",
            "qemu/target/s390x/interrupt.c",
            "qemu/target/s390x/int_helper.c",
            "qemu/target/s390x/ioinst.c",
            "qemu/target/s390x/mem_helper.c",
            "qemu/target/s390x/misc_helper.c",
            "qemu/target/s390x/mmu_helper.c",
            "qemu/target/s390x/sigp.c",
            "qemu/target/s390x/tcg-stub.c",
            "qemu/target/s390x/translate.c",
            "qemu/target/s390x/vec_fpu_helper.c",
            "qemu/target/s390x/vec_helper.c",
            "qemu/target/s390x/vec_int_helper.c",
            "qemu/target/s390x/vec_string_helper.c",
            "qemu/target/s390x/unicorn.c",
        },
        .include_paths = &.{"qemu/target/s390x"},
        .autogen_header_contents = @embedFile("qemu/s390x.h"),
    }, .{
        .CONFIG_SOFTMMU = true,
        .TARGET_S390X = true,
        .TARGET_WORDS_BIGENDIAN = true,
    });

    const libtricore_softmmu = createTargetLibrary(b, host, .{
        .name = "tricore-softmmu",
        .files = &.{
            "qemu/target/tricore/cpu.c",
            "qemu/target/tricore/fpu_helper.c",
            "qemu/target/tricore/helper.c",
            "qemu/target/tricore/op_helper.c",
            "qemu/target/tricore/translate.c",
            "qemu/target/tricore/unicorn.c",
        },
        .include_paths = &.{"qemu/target/tricore"},
        .autogen_header_contents = @embedFile("qemu/tricore.h"),
    }, .{
        .CONFIG_SOFTMMU = true,
        .TARGET_TRICORE = true,
    });

    const libunicorn = unicorn: {
        const mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mod.addConfigHeader(host.config_header);
        for (host.include_paths) |path| mod.addIncludePath(path);
        mod.linkLibrary(libunicorn_common);
        var it = archs.iterator();
        while (it.next()) |arch| {
            switch (arch) {
                .x86 => mod.linkLibrary(libx86_64_softmmu),
                .arm => mod.linkLibrary(libarm_softmmu),
                .aarch64 => mod.linkLibrary(libaarch64_softmmu),
                .m68k => mod.linkLibrary(libm68k_softmmu),
                .mips => {
                    mod.linkLibrary(libmips_softmmu);
                    mod.linkLibrary(libmipsel_softmmu);
                    mod.linkLibrary(libmips64_softmmu);
                    mod.linkLibrary(libmips64el_softmmu);
                },
                .sparc => {
                    mod.linkLibrary(libsparc_softmmu);
                    mod.linkLibrary(libsparc64_softmmu);
                },
                .ppc => {
                    mod.linkLibrary(libppc_softmmu);
                    mod.linkLibrary(libppc64_softmmu);
                },
                .riscv => {
                    mod.linkLibrary(libriscv32_softmmu);
                    mod.linkLibrary(libriscv64_softmmu);
                },
                .s390x => mod.linkLibrary(libs390x_softmmu),
                .tricore => mod.linkLibrary(libtricore_softmmu),
            }
        }
        mod.addCSourceFiles(.{
            .root = b.path(""),
            .files = &.{
                "uc.c",
                "qemu/softmmu/vl.c",
                "qemu/hw/core/cpu.c",
            },
            .flags = cflags,
        });
        const lib = b.addLibrary(.{
            .name = "unicorn",
            .root_module = mod,
        });
        lib.lto = lto;
        lib.installHeadersDirectory(b.path("include/unicorn"), "unicorn", .{});
        break :unicorn lib;
    };

    b.installArtifact(libunicorn);
}
