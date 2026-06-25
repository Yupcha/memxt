const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const is_macos = target.result.os.tag == .macos;

    // ── Main executable ──
    const exe = b.addExecutable(.{
        .name = "memxt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    configureModule(b, exe.root_module, is_macos);
    b.installArtifact(exe);

    // ── Run step ──
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run memxt");
    run_step.dependOn(&run_cmd.step);

    // ── Tests ──
    const test_step = b.step("test", "Run unit tests");

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    configureModule(b, unit_tests.root_module, is_macos);
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}

/// Wire up SQLite, sqlite-vec, and the statically-linked llama.cpp/ggml stack
/// for a module. We link the cmake-produced `.a` archives directly (by path)
/// rather than via `linkSystemLibrary`, so we never accidentally pick up a
/// Homebrew dylib and we end up with a genuinely static binary.
fn configureModule(b: *std.Build, mod: *std.Build.Module, is_macos: bool) void {
    // SQLite is vendored (amalgamation) and compiled in, not linked from the
    // system — so the binary is genuinely self-contained (no libsqlite3 dynamic
    // dep) and cross-compiles cleanly (no system-library lookup for the target).
    mod.addCSourceFile(.{
        .file = b.path("lib/sqlite3.c"),
        .flags = &[_][]const u8{ "-O2", "-DSQLITE_THREADSAFE=1", "-DSQLITE_DQS=0", "-DSQLITE_DEFAULT_MEMSTATUS=0", "-DSQLITE_OMIT_DEPRECATED" },
    });
    mod.addCSourceFile(.{
        .file = b.path("lib/sqlite-vec.c"),
        .flags = &[_][]const u8{ "-O3", "-fomit-frame-pointer", "-DSQLITE_CORE" },
    });

    // Headers.
    mod.addIncludePath(b.path("lib"));
    mod.addIncludePath(b.path("lib/llama.cpp/include"));
    mod.addIncludePath(b.path("lib/llama.cpp/ggml/include"));

    // ── llama.cpp + ggml static archives (cmake output) ──
    // Built via: cmake -S lib/llama.cpp -B lib/llama.cpp/build \
    //   -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    //   -DGGML_METAL=ON(macOS)/OFF(linux) -DGGML_BLAS=ON(macOS)/OFF(linux) \
    //   -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    //   -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_TOOLS=OFF
    // then: cmake --build lib/llama.cpp/build -j
    mod.addObjectFile(b.path("lib/llama.cpp/build/src/libllama.a"));
    mod.addObjectFile(b.path("lib/llama.cpp/build/ggml/src/libggml.a"));
    mod.addObjectFile(b.path("lib/llama.cpp/build/ggml/src/libggml-base.a"));
    mod.addObjectFile(b.path("lib/llama.cpp/build/ggml/src/libggml-cpu.a"));

    // C++ runtime: libc++ on both platforms. On Linux we build llama.cpp with
    // clang + -stdlib=libc++ in CI so the ABI matches here.
    mod.linkSystemLibrary("c++", .{});

    if (is_macos) {
        // Make the macOS SDK frameworks/libs discoverable. Native builds detect
        // these automatically, but cross-compiling (x86_64 on an arm host) does
        // not, so we add the SDK paths explicitly.
        if (sdkPath(b)) |sdk| {
            mod.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
            mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
        }

        // macOS: Metal + Accelerate BLAS backends and the frameworks they need.
        mod.addObjectFile(b.path("lib/llama.cpp/build/ggml/src/ggml-blas/libggml-blas.a"));
        mod.addObjectFile(b.path("lib/llama.cpp/build/ggml/src/ggml-metal/libggml-metal.a"));

        mod.linkFramework("Accelerate", .{});
        mod.linkFramework("Metal", .{});
        mod.linkFramework("MetalKit", .{});
        mod.linkFramework("Foundation", .{});
    }
}

/// Resolve the active macOS SDK path via `xcrun`, or null if unavailable.
fn sdkPath(b: *std.Build) ?[]const u8 {
    const out = b.run(&.{ "xcrun", "--show-sdk-path" });
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}
