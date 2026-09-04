/// Immutable dispatch state returned to Godot by
/// `get_virtual_call_data_func`. Each entry lives in static storage, so the
/// engine may cache its address for as long as the class is registered without
/// an allocation or teardown callback.
pub const VirtualCallData = struct {
    call: c.GDExtensionClassCallVirtual,
};

/// Comptime vtable for virtual method dispatch using StaticStringMap.
/// method_names is an array of Zig method names (camelCase with _ prefix).
/// The VTable computes snake_case keys at comptime for O(1) lookup.
pub fn VTable(comptime T: type, comptime method_names: anytype) type {
    return struct {
        // Zig calling convention for user implementation
        const CallVirtual = gdzig.class.ClassDB.CallVirtual(T);
        // C calling convention wrapper for Godot
        const CCallVirtual = fn (self: *T, args: [*]const *const anyopaque, ret: *anyopaque) callconv(.c) void;
        pub const CallData = VirtualCallData;

        const implemented_count = countImplemented();
        const map: std.StaticStringMap(*const CallData) = .initComptime(blk: {
            var kvs: [implemented_count]struct { []const u8, *const CallData } = undefined;
            var idx: usize = 0;
            for (method_names) |method_name| {
                if (findMethod(method_name)) |wrapper| {
                    // Convert _camelCase method name to _snake_case for lookup key
                    kvs[idx] = .{ casez.comptimeConvert(godot_case.virtual_method, method_name), wrapper };
                    idx += 1;
                }
            }
            break :blk &kvs;
        });

        fn countImplemented() usize {
            @setEvalBranchQuota(100_000);
            var count: usize = 0;
            for (method_names) |name| {
                if (findMethod(name) != null) count += 1;
            }
            return count;
        }

        fn findMethod(comptime method_name: []const u8) ?*const CallData {
            @setEvalBranchQuota(1_000_000);
            const godot_method_name = comptime casez.comptimeConvert(godot_case.virtual_method, method_name);

            // `_ready` is always wrapped, because two things have to happen
            // there whether or not the class wrote one: `Child` fields get
            // filled in, `bind_nodes` entries get bound, and RPC configs get
            // applied. The first two are comptime properties of `T` and could
            // have been tested for; the third is recorded on a runtime
            // `Registry` that this comptime lookup cannot see, so there is
            // nothing to test. The wrapper is a no-op for a class with none of
            // them -- an atomic increment and three empty loops -- and the
            // user's own `_ready`, if present, still runs last.
            //
            // `bindNodes` runs here rather than being called by hand so that the
            // two ways of naming a child behave the same: a `Child` field and a
            // `bind_nodes` entry are both filled before `_ready` sees them.
            //
            // Gated on `T` being a Node because that is what both jobs need --
            // `getNode` for children, `rpcConfig` for RPCs -- and because the
            // vtable's own unit tests build one over a plain struct.
            if (comptime std.mem.eql(u8, method_name, "_ready") and class.isA(class.Node, T)) {
                inline for (class.selfAndAncestorsOf(T)) |Owner| {
                    if (comptime class.isStructClass(Owner) and @hasDecl(Owner, "_ready")) {
                        const Wrapper = struct {
                            const call_data: CallData = .{ .call = @ptrCast(&call) };

                            fn call(p_instance: c.GDExtensionClassInstancePtr, _: [*]const c.GDExtensionConstTypePtr, _: c.GDExtensionTypePtr) callconv(.c) void {
                                const instance: *T = @ptrCast(@alignCast(p_instance));
                                const guard = DispatchGuard.enter(instance);
                                defer guard.leave();
                                child.resolveAll(T, instance);
                                macros.bindNodes(instance);
                                rpc.configureAll(T, instance);
                                const owner = narrowInstance(T, Owner, p_instance);
                                Owner._ready(owner);
                            }
                        };
                        return &Wrapper.call_data;
                    }
                }

                // `_ready` still needs a wrapper when the class declares no
                // callback: child/RPC setup is itself ready-time work.
                const Wrapper = struct {
                    const call_data: CallData = .{ .call = @ptrCast(&call) };

                    fn call(p_instance: c.GDExtensionClassInstancePtr, _: [*]const c.GDExtensionConstTypePtr, _: c.GDExtensionTypePtr) callconv(.c) void {
                        const instance: *T = @ptrCast(@alignCast(p_instance));
                        const guard = DispatchGuard.enter(instance);
                        defer guard.leave();
                        child.resolveAll(T, instance);
                        macros.bindNodes(instance);
                        rpc.configureAll(T, instance);
                    }
                };
                return &Wrapper.call_data;
            }

            inline for (class.selfAndAncestorsOf(T)) |Owner| {
                if (@hasDecl(Owner, godot_method_name)) {
                    const method = @field(Owner, godot_method_name);
                    const FnType = @TypeOf(method);
                    const fn_info = @typeInfo(FnType).@"fn";
                    const ReturnType = fn_info.return_type orelse void;

                    const param_count = fn_info.params.len;
                    if (param_count == 1) {
                        // Only self parameter - generate simpler wrapper
                        const Wrapper = struct {
                            const call_data: CallData = .{ .call = @ptrCast(&call) };

                            fn call(p_instance: c.GDExtensionClassInstancePtr, _: [*]const c.GDExtensionConstTypePtr, p_ret: c.GDExtensionTypePtr) callconv(.c) void {
                                const instance: *Owner = narrowInstance(T, Owner, p_instance);
                                const guard = DispatchGuard.enter(instance);
                                defer guard.leave();
                                if (ReturnType == void) {
                                    method(instance);
                                } else {
                                    const result = method(instance);
                                    ptrcall.writeVirtualReturn(ReturnType, p_ret, result);
                                }
                            }
                        };
                        return &Wrapper.call_data;
                    } else {
                        // Multiple parameters - build args tuple
                        const Wrapper = struct {
                            const call_data: CallData = .{ .call = @ptrCast(&call) };

                            fn call(p_instance: c.GDExtensionClassInstancePtr, p_args: [*]const c.GDExtensionConstTypePtr, p_ret: c.GDExtensionTypePtr) callconv(.c) void {
                                const instance: *Owner = narrowInstance(T, Owner, p_instance);
                                const guard = DispatchGuard.enter(instance);
                                defer guard.leave();
                                var args: std.meta.ArgsTuple(FnType) = undefined;
                                args[0] = instance;
                                inline for (1..param_count) |j| {
                                    const Arg = fn_info.params[j].type.?;
                                    args[j] = ptrcall.readVirtualArg(Arg, p_args[j - 1]);
                                }
                                if (ReturnType == void) {
                                    @call(.always_inline, method, args);
                                } else {
                                    const result = @call(.always_inline, method, args);
                                    ptrcall.writeVirtualReturn(ReturnType, p_ret, result);
                                }
                            }
                        };
                        return &Wrapper.call_data;
                    }
                }
            }
            return null;
        }

        pub fn has(name: []const u8) bool {
            return map.has(name);
        }

        pub fn get(name: []const u8) c.GDExtensionClassCallVirtual {
            const data = map.get(name) orelse return null;
            return data.call;
        }

        /// Return the stable dispatch entry Godot can cache for `name`.
        pub fn getCallData(name: []const u8) ?*const CallData {
            return map.get(name);
        }

        /// Whether `name` is gdzig's internal spelling of an exposed virtual.
        ///
        /// This asks the declaration list, not `map`: `map` contains only the
        /// virtuals `T` actually implements, while registration needs to know
        /// whether a user declaration *could* override one before building the
        /// user vtable.
        pub fn acceptsInternalName(comptime name: []const u8) bool {
            inline for (method_names) |method_name| {
                if (std.mem.eql(u8, name, method_name)) return true;
            }
            return false;
        }

        /// gdzig's internal spelling when `name` is Godot's snake_case form.
        ///
        pub fn internalNameForGodotName(comptime name: []const u8) ?[]const u8 {
            const candidate = comptime casez.comptimeConvert(gdzig_case.virtual_method, name);
            const maybe_internal_name: ?[]const u8 = comptime if (acceptsInternalName(candidate))
                candidate
            else blk: {
                // Snake case loses acronym capitalization: `_get_id` becomes
                // `_getId`, while the generated declaration is `_getID`.
                for (method_names) |method_name| {
                    if (std.ascii.eqlIgnoreCase(candidate, method_name)) break :blk method_name;
                }
                break :blk null;
            };
            const internal_name = maybe_internal_name orelse return null;

            // casez can also parse camelCase input. Require an exact round trip
            // so `_physicsProcess` identifies the virtual for a diagnostic but
            // is not accepted as Godot's canonical `_physics_process` spelling.
            const godot_name = comptime casez.comptimeConvert(godot_case.virtual_method, internal_name);
            if (!std.mem.eql(u8, name, godot_name)) return null;
            return internal_name;
        }

        /// Godot's spelling for an accidentally used internal camelCase name.
        pub fn suggestGodotName(comptime name: []const u8) ?[]const u8 {
            if (!acceptsInternalName(name)) return null;
            return casez.comptimeConvert(godot_case.virtual_method, name);
        }

        /// Extend this vtable with additional methods from a derived type.
        pub fn extend(comptime Derived: type, comptime override_names: anytype) type {
            // Set here as well as in the callees: `combineNames` computes its
            // own return type by calling `countNew`, which is evaluated before
            // that function's body -- and so before any quota it sets. The
            // budget is shared across the whole comptime call tree, and the
            // name matching below is quadratic in the method count, which for
            // the larger engine classes is substantial.
            @setEvalBranchQuota(1_000_000);
            return VTable(Derived, combineNames(override_names));
        }

        fn countNew(comptime override_names: anytype) usize {
            @setEvalBranchQuota(100_000);
            var count: usize = 0;
            outer: for (override_names) |override_name| {
                for (method_names) |base_name| {
                    if (std.mem.eql(u8, override_name, base_name)) {
                        continue :outer;
                    }
                }
                count += 1;
            }
            return count;
        }

        fn combineNames(comptime override_names: anytype) [method_names.len + countNew(override_names)][]const u8 {
            @setEvalBranchQuota(100_000);
            var combined: [method_names.len + countNew(override_names)][]const u8 = undefined;

            // Copy base names
            for (0..method_names.len) |i| {
                combined[i] = method_names[i];
            }

            // Add override names that aren't already in base
            var i: usize = 0;
            outer: for (override_names) |override_name| {
                for (method_names) |base_name| {
                    if (std.mem.eql(u8, override_name, base_name)) {
                        continue :outer;
                    }
                }
                combined[method_names.len + i] = override_name;
                i += 1;
            }

            return combined;
        }
    };
}

test "narrowInstance walks to the owner when the base is displaced" {
    const Parent = struct { base: *gdzig.class.Object };
    // The `u128` outranks the embedded parent under Zig's descending-alignment
    // field ordering, so the base does not start at byte 0.
    const Derived = struct { base: Parent, wide: u128 = 0 };
    try std.testing.expect(@offsetOf(Derived, "base") != 0);

    var derived: Derived = .{ .base = .{ .base = undefined } };

    // The instance pointer Godot would hand a virtual declared on `Parent`.
    const p_instance: c.GDExtensionClassInstancePtr = @ptrCast(&derived);
    const owner = narrowInstance(Derived, Parent, p_instance);

    try std.testing.expectEqual(@intFromPtr(&derived.base), @intFromPtr(owner));
    // The bug this replaced: reinterpreting the pointer instead of narrowing.
    try std.testing.expect(@intFromPtr(owner) != @intFromPtr(&derived));

    // And the common case, where the method is declared on the class itself,
    // still hands back the same address.
    try std.testing.expectEqual(
        @intFromPtr(&derived),
        @intFromPtr(narrowInstance(Derived, Derived, p_instance)),
    );
}

test "VTable snake_case conversion" {
    const TestVTable = VTable(struct {
        pub fn _enter_tree(_: *@This()) void {}
        pub fn _get_http_response(_: *@This()) void {}
        pub fn _parse_url_string(_: *@This()) void {}
        pub fn _get_id(_: *@This()) void {}
        pub fn _ready(_: *@This()) void {}
        pub fn _physics2d_process(_: *@This()) void {}
        pub fn _physics3d_process(_: *@This()) void {}
        pub fn _get2d_position(_: *@This()) void {}
    }, .{ "_enterTree", "_getHTTPResponse", "_parseURLString", "_getID", "_ready", "_physics2DProcess", "_physics3DProcess", "_get2DPosition" });

    try std.testing.expect(TestVTable.has("_enter_tree"));
    try std.testing.expect(TestVTable.has("_get_http_response"));
    try std.testing.expect(TestVTable.has("_parse_url_string"));
    try std.testing.expect(TestVTable.has("_get_id"));
    try std.testing.expect(TestVTable.has("_ready"));
    try std.testing.expect(TestVTable.has("_physics2d_process"));
    try std.testing.expect(TestVTable.has("_physics3d_process"));
    try std.testing.expect(TestVTable.has("_get2d_position"));
    try std.testing.expect(!TestVTable.has("_not_implemented"));
}

test "VTable extend combines method names" {
    const BaseType = struct {
        pub fn _ready(_: *@This()) void {}
        pub fn _process(_: *@This()) void {}
    };
    const Base = VTable(BaseType, .{ "_ready", "_process" });

    // Derived implements _ready (override) and _enter_tree (new), but also _process (inherited)
    const DerivedType = struct {
        pub fn _ready(_: *@This()) void {}
        pub fn _process(_: *@This()) void {}
        pub fn _enter_tree(_: *@This()) void {}
    };
    const Derived = Base.extend(DerivedType, .{ "_ready", "_enterTree" });

    // All methods should be findable
    try std.testing.expect(Derived.has("_ready"));
    try std.testing.expect(Derived.has("_process")); // from base method_names
    try std.testing.expect(Derived.has("_enter_tree")); // new in derived
}

test "VTable call data is stable and invokes the cached wrapper" {
    const Probe = struct {
        calls: usize = 0,

        pub fn _tick(self: *@This()) void {
            self.calls += 1;
        }
    };
    const ProbeVTable = VTable(Probe, .{"_tick"});

    const first = ProbeVTable.getCallData("_tick").?;
    const second = ProbeVTable.getCallData("_tick").?;
    try std.testing.expectEqual(@intFromPtr(first), @intFromPtr(second));
    try std.testing.expectEqual(ProbeVTable.get("_tick"), first.call);
    try std.testing.expect(ProbeVTable.getCallData("_missing") == null);

    var probe: Probe = .{};
    var no_args: [0]c.GDExtensionConstTypePtr = .{};
    var ret: u8 = 0;
    first.call.?(@ptrCast(&probe), &no_args, @ptrCast(&ret));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "VTable maps Godot names to internal names" {
    const Empty = VTable(struct {}, .{ "_ready", "_physicsProcess", "_getID" });

    // No method is implemented, so none appears in the runtime lookup map.
    try std.testing.expect(!Empty.has("_ready"));

    // Registration can still ask which names are valid overrides and diagnose
    // the spelling users most often copy from Godot's snake_case API.
    try std.testing.expect(Empty.acceptsInternalName("_ready"));
    try std.testing.expect(Empty.acceptsInternalName("_physicsProcess"));
    try std.testing.expect(!Empty.acceptsInternalName("_physics_process"));
    try std.testing.expectEqualStrings("_physicsProcess", Empty.internalNameForGodotName("_physics_process").?);
    try std.testing.expectEqualStrings("_getID", Empty.internalNameForGodotName("_get_id").?);
    try std.testing.expect(Empty.internalNameForGodotName("_physicsProcess") == null);
    try std.testing.expect(Empty.internalNameForGodotName("_not_a_virtual") == null);
    try std.testing.expectEqualStrings("_physics_process", Empty.suggestGodotName("_physicsProcess").?);
}

// The integer/enum/flag assertions below are over-read/portability defense: on a
// little-endian host, a narrow 4-byte read of a valid int64 slot's low word happens to
// reproduce the value anyway, so those cases can't actually fail here. The f32 case is the
// one that discriminates: a narrow read there would misinterpret the low 4 bytes of the
// double-width slot as bit pattern, so it's the regression guard that actually exercises
// the width handling.
test "VTable ptrcall marshals virtual params at engine width" {
    const ProbeEnum = enum(i32) {
        zero = 0,
        one = 1,
        negative = -7,
    };

    const Flags = packed struct(u32) {
        alpha: bool = false,
        beta: bool = false,
        _padding: u30 = 0,
    };

    const Probe = struct {
        got_i32: i32 = 0,
        got_u32: u32 = 0,
        got_f32: f32 = 0,
        got_bool: bool = false,
        got_enum: ProbeEnum = .zero,
        got_flags: Flags = .{},

        pub fn _probe_params(self: *@This(), a: i32, b: u32, c_: f32, d: bool, e: ProbeEnum, f: Flags) void {
            self.got_i32 = a;
            self.got_u32 = b;
            self.got_f32 = c_;
            self.got_bool = d;
            self.got_enum = e;
            self.got_flags = f;
        }
    };

    const ProbeVTable = VTable(Probe, .{"_probeParams"});
    const wrapper = ProbeVTable.get("_probe_params").?;

    // Simulate the engine's ptrcall argument slots: every scalar travels in
    // a full 8-byte slot (int64/double/uint8), with unused high bytes left
    // as stack garbage. Poison everything first so a narrow read/write
    // would be caught reading (or leaving) garbage.
    var slot_i32: [8]u8 align(8) = .{0xAA} ** 8;
    std.mem.writeInt(i64, &slot_i32, -12345, .little);

    var slot_u32: [8]u8 align(8) = .{0xAA} ** 8;
    std.mem.writeInt(i64, &slot_u32, 4_000_000_000, .little); // > i32 max

    var slot_f32: [8]u8 align(8) = .{0xAA} ** 8;
    std.mem.writeInt(u64, &slot_f32, @as(u64, @bitCast(@as(f64, 3.5))), .little);

    var slot_bool: [8]u8 align(8) = .{0xAA} ** 8;
    slot_bool[0] = 1;

    var slot_enum: [8]u8 align(8) = .{0xAA} ** 8;
    std.mem.writeInt(i64, &slot_enum, -7, .little);

    var slot_flags: [8]u8 align(8) = .{0xAA} ** 8;
    std.mem.writeInt(i64, &slot_flags, 0b10, .little); // beta set, alpha clear

    var args: [6]c.GDExtensionConstTypePtr = .{
        @ptrCast(&slot_i32),
        @ptrCast(&slot_u32),
        @ptrCast(&slot_f32),
        @ptrCast(&slot_bool),
        @ptrCast(&slot_enum),
        @ptrCast(&slot_flags),
    };

    var probe: Probe = .{};
    var ret_slot: [8]u8 align(8) = .{0xAA} ** 8;

    wrapper(@ptrCast(&probe), &args, @ptrCast(&ret_slot));

    try std.testing.expectEqual(@as(i32, -12345), probe.got_i32);
    try std.testing.expectEqual(@as(u32, 4_000_000_000), probe.got_u32);
    try std.testing.expectEqual(@as(f32, 3.5), probe.got_f32);
    try std.testing.expectEqual(true, probe.got_bool);
    try std.testing.expectEqual(ProbeEnum.negative, probe.got_enum);
    try std.testing.expect(probe.got_flags.beta);
    try std.testing.expect(!probe.got_flags.alpha);
}

test "VTable ptrcall marshals virtual returns at engine width" {
    const ProbeEnum = enum(i16) {
        neg = -300,
    };

    const Flags = packed struct(u16) {
        a: bool = false,
        b: bool = false,
        _padding: u14 = 0,
    };

    const Returns = struct {
        pub fn _ret_i32(_: *@This()) i32 {
            return -123456;
        }
        pub fn _ret_u32(_: *@This()) u32 {
            return 4_111_222_333;
        }
        pub fn _ret_f32(_: *@This()) f32 {
            return -2.5;
        }
        pub fn _ret_bool(_: *@This()) bool {
            return true;
        }
        pub fn _ret_enum(_: *@This()) ProbeEnum {
            return .neg;
        }
        pub fn _ret_flags(_: *@This()) Flags {
            return .{ .b = true };
        }
        pub fn _ret_u64(_: *@This()) u64 {
            return 0xFFFF_FFFF_FFFF_FFFF;
        }
        pub fn _add_and_return(_: *@This(), x: i32) i32 {
            return x + 1;
        }
    };

    const ReturnsVTable = VTable(Returns, .{
        "_retI32", "_retU32", "_retF32", "_retBool", "_retEnum", "_retFlags", "_retU64", "_addAndReturn",
    });
    var instance: Returns = .{};
    const instance_ptr: c.GDExtensionClassInstancePtr = @ptrCast(&instance);
    var no_args: [0]c.GDExtensionConstTypePtr = .{};

    {
        var ret: [8]u8 align(8) = .{0xAA} ** 8;
        ReturnsVTable.get("_ret_i32").?(instance_ptr, &no_args, @ptrCast(&ret));
        try std.testing.expectEqual(@as(i64, -123456), std.mem.readInt(i64, &ret, .little));
    }
    {
        var ret: [8]u8 align(8) = .{0xAA} ** 8;
        ReturnsVTable.get("_ret_u32").?(instance_ptr, &no_args, @ptrCast(&ret));
        try std.testing.expectEqual(@as(i64, 4_111_222_333), std.mem.readInt(i64, &ret, .little));
    }
    {
        var ret: [8]u8 align(8) = .{0xAA} ** 8;
        ReturnsVTable.get("_ret_f32").?(instance_ptr, &no_args, @ptrCast(&ret));
        const bits = std.mem.readInt(u64, &ret, .little);
        try std.testing.expectEqual(@as(f64, -2.5), @as(f64, @bitCast(bits)));
    }
    {
        var ret: [8]u8 align(8) = .{0xAA} ** 8;
        ReturnsVTable.get("_ret_bool").?(instance_ptr, &no_args, @ptrCast(&ret));
        try std.testing.expectEqual(@as(u8, 1), ret[0]);
    }
    {
        var ret: [8]u8 align(8) = .{0xAA} ** 8;
        ReturnsVTable.get("_ret_enum").?(instance_ptr, &no_args, @ptrCast(&ret));
        try std.testing.expectEqual(@as(i64, -300), std.mem.readInt(i64, &ret, .little));
    }
    {
        var ret: [8]u8 align(8) = .{0xAA} ** 8;
        ReturnsVTable.get("_ret_flags").?(instance_ptr, &no_args, @ptrCast(&ret));
        try std.testing.expectEqual(@as(i64, 0b10), std.mem.readInt(i64, &ret, .little));
    }
    {
        var ret: [8]u8 align(8) = .{0xAA} ** 8;
        ReturnsVTable.get("_ret_u64").?(instance_ptr, &no_args, @ptrCast(&ret));
        try std.testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_FFFF), std.mem.readInt(u64, &ret, .little));
    }
    {
        var arg_slot: [8]u8 align(8) = .{0xAA} ** 8;
        std.mem.writeInt(i64, &arg_slot, 41, .little);
        var args: [1]c.GDExtensionConstTypePtr = .{@ptrCast(&arg_slot)};
        var ret: [8]u8 align(8) = .{0xAA} ** 8;
        ReturnsVTable.get("_add_and_return").?(instance_ptr, &args, @ptrCast(&ret));
        try std.testing.expectEqual(@as(i64, 42), std.mem.readInt(i64, &ret, .little));
    }
}

const std = @import("std");

const c = @import("gdextension");
const casez = @import("casez");
/// The instance a virtual declared on `Owner` should be called with.
///
/// Godot hands every virtual the *most-derived* instance -- the pointer
/// `setInstance` stored -- but Zig has no declaration inheritance, so
/// `findMethod` locates the method on whichever ancestor declares it, and
/// `Owner` is usually not `T`. Reinterpreting the pointer is only right when
/// `Owner` starts at byte 0 of `T`, which nothing enforces: Zig orders fields by
/// descending alignment, so a single field with alignment above the base's
/// displaces it. `test/inheritance` has such a class, and its base sits at a
/// non-zero offset.
///
/// `upcast` walks the real chain, and emits nothing when the offsets are zero,
/// so the ordinary case costs the same.
inline fn narrowInstance(comptime T: type, comptime Owner: type, p_instance: c.GDExtensionClassInstancePtr) *Owner {
    const self: *T = @ptrCast(@alignCast(p_instance));
    if (comptime T == Owner) return self;
    return class.upcast(*Owner, self);
}

const gdzig = @import("gdzig");
const common = @import("common");
const godot_case = common.godot_case;
const gdzig_case = common.gdzig_case;
const class = gdzig.class;
const ptrcall = @import("ptrcall.zig");
const child = @import("../child.zig");
const macros = @import("../macros.zig");
const rpc = @import("../rpc.zig");
const DispatchGuard = gdzig.extension.DispatchGuard;
