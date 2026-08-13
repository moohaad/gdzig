//! Forces semantic analysis of the whole generated binding surface.
//!
//! Zig only analyses functions that are referenced. Building the library
//! therefore proves the generated code *parses*, not that it type-checks: a
//! method nobody calls can contain a type error and `zig build` stays silent.
//! Since bindgen emits thousands of methods and the test suite exercises a few
//! dozen, most of the surface was never being checked at all.
//!
//! This references every declaration reachable from the public namespaces,
//! which makes the compiler analyse each one without running anything. It costs
//! compile time and catches signature-level breakage across the entire API --
//! the class of defect that the `Signal`-shadowing bug belonged to.
//!
//! Generic declarations are skipped: a generic function has no value until it
//! is instantiated, and instantiating every one would require inventing
//! plausible arguments for each.

const std = @import("std");

const gdzig = @import("gdzig.zig");

/// Namespaces whose members are swept. Each is a container of types (classes,
/// builtins, global enums and flags) plus free functions.
const namespaces = .{
    gdzig.builtin,
    gdzig.class,
    gdzig.global,
    gdzig.general,
    gdzig.math,
    gdzig.native,
};

/// References a declaration if doing so is meaningful. Types recurse one level
/// into their own declarations, which is where methods live.
fn refDecl(comptime Container: type, comptime name: []const u8) void {
    const Decl = @TypeOf(@field(Container, name));

    if (Decl == type) {
        const Inner = @field(Container, name);
        switch (@typeInfo(Inner)) {
            // A class or builtin: its declarations are the methods worth
            // analysing. Nested types below this are enums and flags, whose
            // members carry no code, so recursion stops here.
            .@"struct", .@"enum", .@"union", .@"opaque" => refMembers(Inner),
            else => {},
        }
        return;
    }

    // Generic functions cannot be referenced without instantiation.
    const info = @typeInfo(Decl);
    if (info == .@"fn" and info.@"fn".is_generic) return;

    _ = &@field(Container, name);
}

/// References every declaration of `T` without recursing into nested types.
fn refMembers(comptime T: type) void {
    inline for (comptime std.meta.declarations(T)) |decl| {
        const Decl = @TypeOf(@field(T, decl.name));
        if (Decl == type) continue;

        const info = @typeInfo(Decl);
        if (info == .@"fn" and info.@"fn".is_generic) continue;

        _ = &@field(T, decl.name);
    }
}

test "every generated declaration type-checks" {
    @setEvalBranchQuota(2_000_000);
    inline for (namespaces) |ns| {
        inline for (comptime std.meta.declarations(ns)) |decl| {
            refDecl(ns, decl.name);
        }
    }
}
