pub fn generate(ctx: *Context) !void {
    try writeBuiltins(ctx);
    try writeClasses(ctx);
    try writeGlobals(ctx);
    try writeNativeStructures(ctx);
    try writeDispatchTable(ctx);
    try writeModules(ctx);
    try writeSurfaceGeneric(ctx);
}

/// Writes `surface_generic.zig`, which instantiates every generic method at its
/// declared signature.
///
/// `surface.zig` sweeps the binding by referencing each declaration, and skips
/// generic functions -- a generic function has no value until instantiated, and
/// the sweep has no way to invent arguments. That was 13,684 vararg methods, and
/// became 21,849 once class parameters were made `anytype` so callers need no
/// upcast. Leaving them out would mean the ergonomics were bought by dropping an
/// eighth of the surface out of the only check that type-checks method bodies.
///
/// Here the argument types are known, because they are the ones the signature
/// used to state. `@TypeOf` forces a generic body to be analysed without
/// emitting a call, so one line per method restores the coverage.
fn writeSurfaceGeneric(ctx: *const Context) !void {
    var buf: [1024]u8 = undefined;

    const file = try ctx.config.output.createFile(ctx.config.io, "surface_generic.zig", .{});
    defer file.close(ctx.config.io);

    var file_writer = file.writer(ctx.config.io, &buf);
    var writer = &file_writer.interface;
    var w = CodeWriter.init(writer);

    try w.writeLine(
        \\//! Instantiates every generic method so `surface.zig` can analyse it.
        \\//!
        \\//! Generated. See `writeSurfaceGeneric` in bindgen for why this exists.
        \\
        \\const gdzig = @import("gdzig.zig");
        \\
    );

    var groups: usize = 0;
    for (ctx.classes.values()) |*class| {
        var wrote_header = false;
        for (class.functions.values()) |*function| {
            if (function.skip) continue;
            if (!isGenericFunction(function, ctx)) continue;

            if (!wrote_header) {
                // Takes a runtime `Variant` so a vararg tuple built from it is a
                // runtime value. A comptime tuple makes the callee's `&args[i]`
                // a "reference to comptime var" the moment it reaches the
                // ptrcall.
                try w.printLine("fn {s}(v: gdzig.builtin.Variant) void {{", .{class.module});
                w.indent += 1;
                // Discarded only when nothing here is variadic; discarding a
                // parameter that is also used is itself an error.
                var uses_v = false;
                for (class.functions.values()) |*f| {
                    if (!f.skip and f.mode == .final and f.is_vararg) {
                        uses_v = true;
                        break;
                    }
                }
                if (!uses_v) try w.writeLine("_ = v;");
                wrote_header = true;
                groups += 1;
            }
            try writeInstantiation(&w, function, class, ctx, "");
            if (function.is_vararg) try writeInstantiation(&w, function, class, ctx, "Alloc");
        }
        if (wrote_header) {
            w.indent -= 1;
            try w.writeLine("}");
            try w.writeLine("");
        }
    }

    try w.writeLine("pub fn all() void {");
    w.indent += 1;
    for (ctx.classes.values()) |*class| {
        var any = false;
        for (class.functions.values()) |*function| {
            if (function.skip) continue;
            if (isGenericFunction(function, ctx)) {
                any = true;
                break;
            }
        }
        // `&` not `()`: referencing forces the body to be analysed, calling it
        // would run every method in the binding against undefined arguments.
        if (any) try w.printLine("_ = &{s};", .{class.module});
    }
    w.indent -= 1;
    try w.writeLine("}");

    try writer.flush();
}

/// Whether the emitted signature contains an `anytype`, and so is skipped by the
/// declaration sweep.
fn isGenericFunction(function: *const Context.Function, ctx: *const Context) bool {
    // Virtuals are for the user to implement; no callable decl is emitted.
    if (function.mode != .final) return false;
    if (function.is_vararg) return true;
    for (function.parameters.values()) |param| {
        if (param.default != null) break; // optional params keep concrete types
        if (param.type == .class) return true;
        _ = ctx;
    }
    return false;
}

/// One `@TypeOf` call, with the argument types the signature used to state.
/// Values are `undefined` throughout: nothing runs, only the body is analysed.
fn writeInstantiation(w: *CodeWriter, function: *const Context.Function, class: *const Context.Class, ctx: *const Context, suffix: []const u8) !void {
    if (function.return_type != .void) try w.writeAll("_ = ");
    try w.print("gdzig.class.{s}.", .{class.name});
    if (std.zig.Token.keywords.has(function.name) and suffix.len == 0) {
        try w.print("@\"{s}\"(", .{function.name});
    } else {
        try w.print("{s}{s}(", .{ function.name, suffix });
    }

    var is_first = true;
    switch (function.self) {
        .static, .singleton => {},
        else => {
            try w.writeAll("undefined");
            is_first = false;
        },
    }

    var opt: usize = function.parameters.count();
    for (function.parameters.values(), 0..) |param, i| {
        if (param.default != null) {
            opt = i;
            break;
        }
        if (!is_first) try w.writeAll(", ");
        if (function.is_vararg and param.type.allocatesAsVariant(ctx)) {
            // Declared `Variant` rather than `anytype` on the vararg path.
            try w.writeAll("undefined");
        } else if (param.type == .class) {
            // The one argument whose type the signature no longer carries.
            // Fully qualified: this file imports `gdzig` and nothing else.
            const api_name = param.type.class;
            const name = if (ctx.classes.get(api_name)) |c| c.name else api_name;
            try w.print("@as(*gdzig.class.{s}, undefined)", .{name});
        } else {
            try w.writeAll("undefined");
        }
        is_first = false;
    }

    if (function.is_vararg) {
        if (!is_first) try w.writeAll(", ");
        // Not `.{}`: with no required parameters either, `args` would be a
        // zero-length array and the Alloc path's `&args[0]` is then a comptime
        // out-of-bounds index. One Variant keeps it in range.
        try w.writeAll(".{v}");
        is_first = false;
    }

    if (opt < function.parameters.count()) {
        if (!is_first) try w.writeAll(", ");
        try w.writeAll(".{}");
    }

    try w.writeLine(");");
}

fn writeBuiltins(ctx: *const Context) !void {
    var buf: [1024]u8 = undefined;

    // builtin.zig
    {
        const file = try ctx.config.output.createFile(ctx.config.io, "builtin.zig", .{});
        defer file.close(ctx.config.io);

        var file_writer = file.writer(ctx.config.io, &buf);
        var writer = &file_writer.interface;
        var w: CodeWriter = .init(writer);

        try writeMixin(&w, "builtin.mixin.zig", .{}, ctx);

        // Variant is a special case, since it is not a generated file.
        try w.writeLine(
            \\pub const Variant = @import("builtin/variant.zig").Variant;
            \\
        );
        for (ctx.builtins.values()) |builtin| {
            try w.printLine(
                \\pub const {1s} = @import("builtin/{0s}.zig").{1s};
            , .{ builtin.module, builtin.name });
        }

        try w.writeLine(
            \\
            \\test {
            \\  @import("std").testing.refAllDecls(@This());
            \\}
        );

        try writer.flush();
    }

    // builtin/[name].zig
    try ctx.config.output.createDirPath(ctx.config.io, "builtin");

    for (ctx.builtins.values()) |*builtin| {
        const filename = try std.fmt.allocPrint(ctx.arena.allocator(), "builtin/{s}.zig", .{builtin.module});
        const file = try ctx.config.output.createFile(ctx.config.io, filename, .{});
        defer file.close(ctx.config.io);

        var file_writer = file.writer(ctx.config.io, &buf);
        var writer = &file_writer.interface;
        var cw = CodeWriter.init(writer);

        try writeBuiltin(&cw, builtin, ctx);

        try writer.flush();
    }
}

fn writeBuiltin(w: *CodeWriter, builtin: *const Context.Builtin, ctx: *const Context) !void {
    try writeDocBlock(w, builtin.doc);

    // Declaration start
    try w.printLine(
        \\pub const {0s} = extern struct {{
    , .{builtin.name});
    w.indent += 1;

    // Memory layout assertions
    try w.printLine(
        \\comptime {{
        \\    if (@sizeOf({0s}) != {1d}) @compileError("expected {0s} to be {1d} bytes");
    , .{ builtin.name, builtin.size });
    w.indent += 1;
    for (builtin.fields.values()) |*field| {
        if (field.offset) |offset| {
            try w.printLine(
                \\if (@offsetOf({1s}, "{0s}") != {2d}) @compileError("expected the offset of '{0s}' on '{1s}' to be {2d}");
            , .{ field.name, builtin.name, offset });
        }
    }
    w.indent -= 1;
    try w.writeLine(
        \\}
        \\
    );

    // Fields
    if (builtin.fields.count() == 0) {
        try w.printLine(
            \\/// {0s} is an opaque data structure; these bytes are not meant to be accessed directly.
            \\_: [{1d}]u8,
            \\
        , .{ builtin.name, builtin.size });
    } else if (builtin.fields.count() > 0) {
        for (builtin.fields.values()) |*field| {
            if (field.offset != null) {
                try writeField(w, field, null, ctx);
            }
        }
    }

    // Constants
    for (builtin.constants.values()) |*constant| {
        if (constant.skip) continue;

        try writeConstant(w, constant, null, ctx);
    }

    if (builtin.constants.count() > 0) {
        try w.writeLine("");
    }

    // Constructors
    for (builtin.constructors.values()) |*constructor| {
        if (constructor.skip) continue;

        try writeBuiltinConstructor(w, builtin.name, constructor, ctx);
        try w.writeLine("");
    }

    // Destructor
    if (builtin.has_destructor) {
        try writeBuiltinDestructor(w, builtin);
        try w.writeLine("");
    }

    // Methods
    for (builtin.methods.values()) |*method| {
        if (method.skip) continue;

        try writeBuiltinMethod(w, builtin.name, method, ctx);
        try w.writeLine("");
    }

    // Operators
    for (builtin.operators.items) |*operator| {
        try writeBuiltinOperator(w, builtin.name, operator, ctx);
        try w.writeLine("");
    }

    // Enums
    for (builtin.enums.values()) |*@"enum"| {
        try writeEnum(w, @"enum", ctx);
        try w.writeLine("");
    }

    // Helpers
    try w.printLine(
        \\/// Returns an opaque pointer to the {0s}.
        \\pub fn ptr(self: *{0s}) *anyopaque {{
        \\    return @ptrCast(self);
        \\}}
        \\
        \\/// Returns a constant opaque pointer to the {0s}.
        \\pub fn constPtr(self: *const {0s}) *const anyopaque {{
        \\    return @ptrCast(self);
        \\}}
        \\
    , .{builtin.name});

    // Mixin
    try writeMixin(w, "builtin/{s}.mixin.zig", .{builtin.name}, ctx);

    // Declaration end
    w.indent -= 1;
    try w.writeLine("};");

    // Imports
    try writeImports(w, &builtin.imports, null, ctx);
}

fn writeBuiltinConstructor(w: *CodeWriter, builtin_name: []const u8, constructor: *const Context.Function, ctx: *const Context) !void {
    try writeFunctionHeader(w, constructor, null, ctx);
    if (constructor.can_init_directly) {
        for (constructor.parameters.values()) |param| {
            if (param.type.castFunction()) |cast_fn| {
                try w.printLine(
                    \\result.{0s} = {2s}({1s});
                , .{ param.field_name.?, param.name, cast_fn });
            } else {
                try w.printLine(
                    \\result.{0s} = {1s};
                , .{ param.field_name.?, param.name });
            }
        }
    } else {
        try w.printLine(
            \\var _bind = {0s}_ptr.load(.monotonic);
            \\if (_bind == null) {{
            \\    _bind = raw.variantGetPtrConstructor(@intFromEnum(Variant.Tag.forType({2s})), {1d});
            \\    {0s}_ptr.store(_bind, .monotonic);
            \\}}
            \\_bind.?(@ptrCast(&result), @ptrCast(&args));
        , .{
            constructor.name,
            constructor.index.?,
            builtin_name,
        });
    }
    try writeFunctionFooter(w, constructor, null, ctx);
    if (!constructor.can_init_directly) {
        try w.printLine(
            \\var {0s}_ptr: std.atomic.Value(c.GDExtensionPtrConstructor) = .init(null);
        , .{constructor.name});
    }
}

fn writeBuiltinDestructor(w: *CodeWriter, builtin: *const Context.Builtin) !void {
    try w.printLine(
        \\pub fn deinit(self: *{0s}) void {{
        \\    var _bind = deinit_ptr.load(.monotonic);
        \\    if (_bind == null) {{
        \\        _bind = raw.variantGetPtrDestructor(@intFromEnum(Variant.Tag.forType({0s}))).?;
        \\        deinit_ptr.store(_bind, .monotonic);
        \\    }}
        \\    _bind.?(@ptrCast(self));
        \\}}
        \\var deinit_ptr: std.atomic.Value(c.GDExtensionPtrDestructor) = .init(null);
        \\
    , .{
        builtin.name,
    });
}

fn writeBuiltinMethod(w: *CodeWriter, builtin_name: []const u8, method: *const Context.Function, ctx: *const Context) !void {
    try writeFunctionHeader(w, method, null, ctx);

    try w.printLine(
        \\var _bind = {0s}_ptr.load(.monotonic);
        \\if (_bind == null) {{
        \\    _bind = raw.variantGetPtrBuiltinMethod(@intFromEnum(Variant.Tag.forType({3s})), @ptrCast(StringName.fromComptimeLatin1("{1s}")), {2d}).?;
        \\    {0s}_ptr.store(_bind, .monotonic);
        \\}}
        \\_bind.?({4s}, @ptrCast(&args), {5s}, args.len);
    , .{
        method.name,
        method.name_api,
        method.hash.?,
        builtin_name,
        switch (method.self) {
            .static => "null",
            .singleton => @panic("singleton builtins not supported"),
            .constant => "@ptrCast(@constCast(self))",
            .mutable => "@ptrCast(self)",
            .value => "@ptrCast(@constCast(&self))",
        },
        if (method.return_type != .void) "@ptrCast(&result)" else "null",
    });
    try writeFunctionFooter(w, method, null, ctx);
    try w.printLine(
        \\var {0s}_ptr: std.atomic.Value(c.GDExtensionPtrBuiltInMethod) = .init(null);
    , .{method.name});
}

fn writeBuiltinOperator(w: *CodeWriter, builtin_name: []const u8, operator: *const Context.Function, ctx: *const Context) !void {
    try writeFunctionHeader(w, operator, null, ctx);

    // Lookup the method
    try w.print(
        \\var _bind = {0s}_ptr.load(.monotonic);
        \\if (_bind == null) {{
        \\    _bind = raw.variantGetPtrOperatorEvaluator(@intFromEnum(Variant.Operator.{1s}), @intFromEnum(Variant.Tag.forType({2s})),
    , .{ operator.name, operator.operator_name.?, builtin_name });
    w.indent += 1;
    if (operator.parameters.getPtr("rhs")) |rhs| {
        try w.writeAll(" @intFromEnum(Variant.Tag.forType(");
        try writeTypeAtField(w, &rhs.type, null, ctx);
        try w.writeAll("))");
    } else {
        // Unary operator: there is no right operand, which the engine spells as
        // the NIL variant type. The parameter is a GDExtensionVariantType, not a
        // pointer, so `null` does not type-check here.
        try w.writeAll(" @intFromEnum(Variant.Tag.nil)");
    }
    w.indent -= 1;
    try w.writeLine(");");
    try w.printLine("    {0s}_ptr.store(_bind, .monotonic);", .{operator.name});
    try w.writeLine("}");

    // Call the method
    try w.writeAll("_bind.?(");
    w.indent += 1;
    try w.writeAll("@ptrCast(self), ");
    if (operator.parameters.getPtr("rhs")) |_| {
        try w.writeAll("@ptrCast(&rhs), ");
    } else {
        try w.writeAll("null, ");
    }
    try w.writeAll("@ptrCast(&result)");
    w.indent -= 1;
    try w.writeLine(");");

    try writeFunctionFooter(w, operator, null, ctx);
    try w.printLine(
        \\var {0s}_ptr: std.atomic.Value(c.GDExtensionPtrOperatorEvaluator) = .init(null);
    , .{operator.name});
}

fn writeClasses(ctx: *const Context) !void {
    var buf: [1024]u8 = undefined;

    // class.zig
    {
        const file = try ctx.config.output.createFile(ctx.config.io, "class.zig", .{});
        defer file.close(ctx.config.io);

        var file_writer = file.writer(ctx.config.io, &buf);
        var writer = &file_writer.interface;
        var w = CodeWriter.init(writer);

        try writeMixin(&w, "class.mixin.zig", .{}, ctx);

        for (ctx.classes.values()) |class| {
            try w.printLine(
                \\pub const {1s} = @import("class/{0s}.zig").{1s};
            , .{ class.module, class.name });
        }

        try w.writeLine(
            \\
            \\test {
            \\  @setEvalBranchQuota(20000);
            \\  @import("std").testing.refAllDecls(@This());
            \\}
        );

        try writer.flush();
    }

    // class/[name].zig
    try ctx.config.output.createDirPath(ctx.config.io, "class");
    for (ctx.classes.values()) |*class| {
        const filename = try std.fmt.allocPrint(ctx.rawAllocator(), "class/{s}.zig", .{class.module});
        defer ctx.rawAllocator().free(filename);

        const file = try ctx.config.output.createFile(ctx.config.io, filename, .{});
        defer file.close(ctx.config.io);

        var file_writer = file.writer(ctx.config.io, &buf);
        var writer = &file_writer.interface;
        var w = CodeWriter.init(writer);

        try writeClass(&w, class, ctx);

        try writer.flush();
    }
}

fn writeClass(w: *CodeWriter, class: *const Context.Class, ctx: *const Context) !void {
    try writeDocBlock(w, class.doc);

    // Declaration start
    try w.printLine(
        \\pub const {0s} = opaque {{
    , .{class.name});
    w.indent += 1;

    // Base class
    if (class.base) |base| {
        try w.printLine(
            \\pub const Base = {0s};
            \\
        , .{base});
    } else {
        try w.writeLine(
            \\pub const Base = void;
            \\
        );
    }

    // Singleton storage
    //
    // Atomic for the same reason the method-bind caches are: `globalGetSingleton`
    // is called lazily on first use, from whichever thread gets there first.
    if (class.is_singleton) {
        try w.printLine(
            \\pub var instance: std.atomic.Value(?*{0s}) = .init(null);
        , .{class.name});
    }

    // Constants
    for (class.constants.values()) |*constant| {
        if (constant.skip) continue;

        try writeConstant(w, constant, class, ctx);
    }
    if (class.constants.count() > 0) {
        try w.writeLine("");
    }

    // Signals
    for (class.signals.values()) |*signal| {
        try writeSignal(w, signal, class, ctx);
        try w.writeLine("");
    }

    // Constructor
    if (class.is_instantiable) {
        if (class.is_refcounted) {
            // Godot leaves a freshly constructed RefCounted's initial reference
            // "pending": refcount is 1, but nothing has claimed it yet. The
            // first time engine code wraps the raw pointer in a Ref<T> (e.g. as
            // a temporary inside some unrelated method call), it silently
            // consumes that pending ref without incrementing the count, so
            // releasing that temporary drops the count to zero and frees the
            // object out from under the caller. Consuming the pending ref here
            // (mirroring Ref<T>::instantiate()) makes init() return an object
            // that is plainly owned at refcount 1, like everything else.
            try w.printLine(
                \\/// Allocates an empty {0s} with a refcount of 1, owned by the returned handle.
                \\///
                \\/// Release it with `deinit`, or take the bare pointer back out with
                \\/// `release` if you need to store it somewhere a handle cannot go,
                \\/// such as a class's `base` field.
                \\pub fn init() Gd({0s}) {{
                \\    const self: *{0s} = @ptrCast(raw.classdbConstructObject(@ptrCast(StringName.fromComptimeLatin1("{1s}"))).?);
                \\    _ = self.initRef();
                \\    return .adopt(self);
                \\}}
                \\
            , .{ class.name, class.name_api });
        } else {
            try w.printLine(
                \\/// Allocates an empty {0s}.
                \\pub fn init() *{0s} {{
                \\    return @ptrCast(raw.classdbConstructObject(@ptrCast(StringName.fromComptimeLatin1("{1s}"))).?);
                \\}}
                \\
            , .{ class.name, class.name_api });
        }
    }

    // Functions
    for (class.functions.values()) |*function| {
        if (function.skip) continue;

        if (function.mode != .final) continue;
        try writeClassFunction(w, class, function, ctx);
        try w.writeLine("");

        // Write allocating wrapper for vararg functions
        if (function.is_vararg) {
            try writeFunctionAlloc(w, function, class, ctx);
            try w.writeLine("");
        }
    }

    // Properties
    for (class.properties.values()) |*property| {
        try writeClassProperty(w, class, property, ctx);
    }

    // Virtual dispatch
    try writeClassVirtualDispatch(w, class, ctx);
    try w.writeLine("");

    // Enums
    for (class.enums.values()) |*@"enum"| {
        try writeEnum(w, @"enum", ctx);
        try w.writeLine("");
    }

    // Flags
    for (class.flags.values()) |*flag| {
        try writeFlag(w, flag, ctx);
        try w.writeLine("");
    }

    // Self alias and name for mixins
    try w.printLine(
        \\const Self = @This();
        \\const self_name = "{0s}";
        \\
    , .{class.name_api});

    // Mixins (include parent class mixins)
    try writeClassMixins(w, class, ctx);

    // Declaration end
    w.indent -= 1;
    try w.writeLine("};");

    // Imports (with collision detection for signals/enums/flags)
    try writeImports(w, &class.imports, class, ctx);
}

fn writeSignal(w: *CodeWriter, signal: *const Context.Signal, class: *const Context.Class, ctx: *const Context) !void {
    try writeDocBlock(w, signal.doc);
    try w.print("pub const {s} = struct {{", .{signal.struct_name});

    if (signal.parameters.count() > 0) {
        try w.writeLine("");
    }

    w.indent += 1;
    for (signal.parameters.values()) |param| {
        try w.print("{s}: ", .{param.name});
        try w.writeAll("?");
        try writeTypeAtField(w, &param.type, class, ctx);
        try w.writeLine(" = null,");
    }
    w.indent -= 1;

    try w.writeLine("};");
}

fn writeClassFunction(w: *CodeWriter, class: *const Context.Class, function: *const Context.Function, ctx: *const Context) !void {
    // For vararg functions, generate a thin wrapper that does comptime check + delegates to Alloc version
    if (function.is_vararg) {
        try writeClassFunctionVarargWrapper(w, class, function, ctx);
        return;
    }

    try writeFunctionHeader(w, function, class, ctx);

    if (class.is_singleton) {
        try w.writeLine(
            \\var _singleton = instance.load(.monotonic);
            \\if (_singleton == null) {
            \\    _singleton = @ptrCast(raw.globalGetSingleton(@ptrCast(StringName.fromComptimeLatin1(self_name))).?);
            \\    instance.store(_singleton, .monotonic);
            \\}
        );
    }

    try w.printLine(
        \\var _bind = {0s}_ptr.load(.monotonic);
        \\if (_bind == null) {{
        \\    _bind = raw.classdbGetMethodBind(@ptrCast(StringName.fromComptimeLatin1("{2s}")), @ptrCast(StringName.fromComptimeLatin1("{1s}")), {3d});
        \\    {0s}_ptr.store(_bind, .monotonic);
        \\}}
    , .{
        function.name,
        function.name_api,
        function.base.?,
        function.hash.?,
    });

    try w.writeAll("raw.objectMethodBindPtrcall(_bind, ");
    try writeClassFunctionObjectPtr(w, class, function, ctx);
    try w.printLine(", @ptrCast(&args), {s});", .{
        if (function.return_type != .void)
            "@ptrCast(&result)"
        else
            "null",
    });

    try writeFunctionFooter(w, function, class, ctx);
    try w.printLine(
        \\var {0s}_ptr: std.atomic.Value(c.GDExtensionMethodBindPtr) = .init(null);
    , .{function.name});
}

/// Writes a thin vararg wrapper that does comptime check and delegates to the Alloc version.
fn writeClassFunctionVarargWrapper(w: *CodeWriter, class: *const Context.Class, function: *const Context.Function, ctx: *const Context) !void {
    try w.writeLine(
        \\/// Guarantees no allocations when calling across the FFI. Passing packed arrays is a compile error; use the Alloc variant.
        \\///
    );
    try writeDocBlock(w, function.doc);

    // Function signature
    if (std.zig.Token.keywords.has(function.name)) {
        try w.print("pub fn @\"{s}\"(", .{function.name});
    } else {
        try w.print("pub fn {s}(", .{function.name});
    }

    var is_first = true;
    const has_self = switch (function.self) {
        .static, .singleton => false,
        else => true,
    };

    if (has_self) {
        try w.print("self: *{s}", .{class.name});
        is_first = false;
    }

    for (function.parameters.values()) |param| {
        if (!is_first) try w.writeAll(", ");
        try w.print("{s}: ", .{param.name});
        try writeTypeAtParameter(w, &param.type, class, ctx);
        is_first = false;
    }

    if (!is_first) try w.writeAll(", ");
    try w.writeAll("@\"...\": anytype) ");
    try writeTypeAtReturn(w, &function.return_type, class, ctx);
    try w.writeLine(" {");
    w.indent += 1;

    // Comptime check - skip Variant type (already a Variant, no wrapping needed)
    try w.printLine(
        \\inline for (0..@"...".len) |_i| {{
        \\    if (@TypeOf(@"..."[_i]) != Variant and comptime Variant.Tag.allocatesForType(@TypeOf(@"..."[_i]))) {{
        \\        @compileError(@typeName(@TypeOf(@"..."[_i])) ++ " requires allocation; use {s}Alloc() or pass a Variant instead.");
        \\    }}
        \\}}
    , .{function.name});

    // Delegate to Alloc version
    if (function.return_type != .void) {
        try w.writeAll("return ");
    }

    if (has_self) {
        try w.print("self.{s}Alloc(", .{function.name});
    } else {
        try w.print("{s}Alloc(", .{function.name});
    }

    is_first = true;
    for (function.parameters.values()) |param| {
        if (!is_first) try w.writeAll(", ");
        try w.print("{s}", .{param.name});
        is_first = false;
    }

    if (!is_first) try w.writeAll(", ");
    try w.writeLine("@\"...\");");

    w.indent -= 1;
    try w.writeLine("}");
}

/// Writes the allocating version of a vararg function that does the actual FFI call.
fn writeFunctionAlloc(w: *CodeWriter, function: *const Context.Function, class: ?*const Context.Class, ctx: *const Context) !void {
    try w.writeLine(
        \\/// Will allocate when calling across the FFI with packed arrays.
        \\///
    );
    try writeDocBlock(w, function.doc);

    // Declaration with Alloc suffix
    if (std.zig.Token.keywords.has(function.name)) {
        try w.print("pub fn @\"{s}Alloc\"(", .{function.name});
    } else {
        try w.print("pub fn {s}Alloc(", .{function.name});
    }

    var is_first = true;

    // Self parameter
    switch (function.self) {
        .static, .singleton => {},
        .constant => |api_name| {
            const name = if (ctx.classes.get(api_name)) |c| c.name else if (ctx.builtins.get(api_name)) |b| b.name else api_name;
            try w.print("self: *const {0s}", .{name});
            is_first = false;
        },
        .mutable => |api_name| {
            const name = if (ctx.classes.get(api_name)) |c| c.name else if (ctx.builtins.get(api_name)) |b| b.name else api_name;
            try w.print("self: *{0s}", .{name});
            is_first = false;
        },
        .value => |api_name| {
            const name = if (ctx.classes.get(api_name)) |c| c.name else if (ctx.builtins.get(api_name)) |b| b.name else api_name;
            try w.print("self: {0s}", .{name});
            is_first = false;
        },
    }

    // Positional parameters
    for (function.parameters.values()) |param| {
        if (!is_first) {
            try w.writeAll(", ");
        }
        try w.print("{s}: ", .{param.name});
        try writeTypeAtParameter(w, &param.type, class, ctx);
        is_first = false;
    }

    // Variadic parameters as anytype
    if (!is_first) {
        try w.writeAll(", ");
    }
    try w.writeAll("@\"...\": anytype");

    // Return type
    try w.writeAll(") ");
    try writeTypeAtReturn(w, &function.return_type, class, ctx);
    try w.writeLine(" {");
    w.indent += 1;

    const param_count = function.parameters.count();

    // Build pointer array to stack-temporary Variants
    try w.printLine("var args: [{d} + @\"...\".len]*Variant = undefined;", .{param_count});

    // Fixed parameters - wrap in Variant (unless already Variant)
    // Use wrap() for non-allocating types, init() for allocating types (packed arrays)
    for (function.parameters.values(), 0..) |param, i| {
        if (param.type == .variant) {
            try w.printLine("args[{d}] = @constCast(&{s});", .{ i, param.name });
        } else {
            // Check if this type requires allocation (packed arrays)
            const needs_alloc = if (param.type == .basic) blk: {
                const name = param.type.basic;
                break :blk std.mem.startsWith(u8, name, "Packed");
            } else false;

            if (needs_alloc) {
                try w.print("args[{d}] = @constCast(&Variant.init(", .{i});
                try writeTypeAtParameter(w, &param.type, class, ctx);
                try w.printLine(", {s}));", .{param.name});
                try w.printLine("defer args[{d}].deinit();", .{i});
            } else if (param.type == .class) {
                // `Variant.wrap` needs a type, and a class parameter's declared
                // type is now `anytype`. Narrow it first, as the ptrcall path
                // does, then wrap the narrowed local.
                try w.print("const arg{d}_obj: ", .{i});
                try writeClassPointerType(w, param.type.class, class, ctx);
                try w.print(" = gdzig.class.upcast(", .{});
                try writeClassPointerType(w, param.type.class, class, ctx);
                try w.printLine(", {s});", .{param.name});
                try w.print("args[{d}] = @constCast(&Variant.wrap(", .{i});
                try writeClassPointerType(w, param.type.class, class, ctx);
                try w.printLine(", &arg{d}_obj));", .{i});
            } else {
                try w.print("args[{d}] = @constCast(&Variant.wrap(", .{i});
                try writeTypeAtParameter(w, &param.type, class, ctx);
                try w.printLine(", &{s}));", .{param.name});
            }
        }
    }

    // Varargs - check if already a Variant before wrapping
    // Use wrap() for non-allocating types, init() for allocating types (packed arrays)
    try w.printLine("inline for (0..@\"...\".len, {d}..args.len) |i, j| {{", .{param_count});
    w.indent += 1;
    try w.writeLine("if (@TypeOf(@\"...\"[i]) == Variant) {");
    w.indent += 1;
    try w.writeLine("args[j] = @constCast(&@\"...\"[i]);");
    w.indent -= 1;
    try w.writeLine("} else if (comptime Variant.Tag.allocatesForType(@TypeOf(@\"...\"[i]))) {");
    w.indent += 1;
    try w.writeLine("args[j] = @constCast(&Variant.init(@TypeOf(@\"...\"[i]), @\"...\"[i]));");
    w.indent -= 1;
    try w.writeLine("} else {");
    w.indent += 1;
    try w.writeLine("const val = @\"...\"[i];");
    try w.writeLine("args[j] = @constCast(&Variant.wrap(@TypeOf(val), &val));");
    w.indent -= 1;
    try w.writeLine("}");
    w.indent -= 1;
    try w.writeLine("}");

    // Defer deinit for varargs - only for allocating types (packed arrays)
    try w.printLine("defer inline for (0..@\"...\".len, {d}..args.len) |i, j| {{", .{param_count});
    w.indent += 1;
    try w.writeLine("if (@TypeOf(@\"...\"[i]) != Variant and comptime Variant.Tag.allocatesForType(@TypeOf(@\"...\"[i]))) {");
    w.indent += 1;
    try w.writeLine("args[j].deinit();");
    w.indent -= 1;
    try w.writeLine("}");
    w.indent -= 1;
    try w.writeLine("};");

    // Return variable
    try w.writeLine("var result: Variant = .nil;");

    // Method bind lookup and call
    if (class) |cls| {
        try w.writeLine("var err: c.GDExtensionCallError = undefined;");
        // Class method
        if (cls.is_singleton) {
            try w.writeLine("var _singleton = instance.load(.monotonic);");
            try w.writeLine("if (_singleton == null) {");
            w.indent += 1;
            try w.writeLine("_singleton = @ptrCast(raw.globalGetSingleton(@ptrCast(StringName.fromComptimeLatin1(self_name))).?);");
            try w.writeLine("instance.store(_singleton, .monotonic);");
            w.indent -= 1;
            try w.writeLine("}");
        }

        try w.printLine("var _bind = {0s}Alloc_ptr.load(.monotonic);", .{function.name});
        try w.writeLine("if (_bind == null) {");
        w.indent += 1;
        try w.printLine("_bind = raw.classdbGetMethodBind(@ptrCast(StringName.fromComptimeLatin1(\"{0s}\")), @ptrCast(StringName.fromComptimeLatin1(\"{1s}\")), {2d});", .{
            function.base.?,
            function.name_api,
            function.hash.?,
        });
        try w.printLine("{0s}Alloc_ptr.store(_bind, .monotonic);", .{function.name});
        w.indent -= 1;
        try w.writeLine("}");

        try w.writeAll("raw.objectMethodBindCall(_bind, ");
        try writeClassFunctionObjectPtr(w, cls, function, ctx);
        try w.writeLine(", @ptrCast(@alignCast(&args[0])), @intCast(args.len), @ptrCast(&result), &err);");
    } else {
        // Utility function
        try w.printLine("var _bind = {0s}Alloc_ptr.load(.monotonic);", .{function.name});
        try w.writeLine("if (_bind == null) {");
        w.indent += 1;
        try w.printLine("_bind = raw.variantGetPtrUtilityFunction(@ptrCast(@constCast(StringName.fromComptimeLatin1(\"{0s}\"))), {1d});", .{
            function.name_api,
            function.hash.?,
        });
        try w.printLine("{0s}Alloc_ptr.store(_bind, .monotonic);", .{function.name});
        w.indent -= 1;
        try w.writeLine("}");
        try w.writeLine("_bind.?(@ptrCast(&result), @ptrCast(&args), @intCast(args.len));");
    }

    // Return.
    //
    // Unlike the ptrcall path, a vararg call comes back in a `Variant` that owns
    // what it holds: heap data for a `String` or `Callable`, a reference for a
    // `RefCounted`. `as` copies scalars but only *borrows* an object pointer, so
    // anything that has to outlive the Variant must be taken before it is
    // released.
    switch (function.return_type) {
        // Handed straight back, so the caller inherits the Variant and the job
        // of releasing it.
        .variant => try w.writeLine("return result;"),

        .void => {},

        .class => |api_name| {
            try w.writeLine("defer result.deinit();");
            if (ctx.isRefCounted(api_name)) {
                // `borrow`, not `adopt`: the reference belongs to the Variant
                // and the deferred release above drops it, so the handle needs
                // one of its own.
                try w.writeAll("return if (result.as(*");
                try writeClassName(w, api_name, class, ctx);
                try w.writeAll(")) |_ptr| Gd(");
                try writeClassName(w, api_name, class, ctx);
                try w.writeLine(").borrow(_ptr) else null;");
            } else {
                // Not refcounted, so the Variant never owned it and the bare
                // pointer outlives the release below.
                try w.writeAll("return result.as(*");
                try writeClassName(w, api_name, class, ctx);
                try w.writeLine(");");
            }
        },

        else => {
            try w.writeLine("defer result.deinit();");
            try w.writeAll("return result.as(");
            try writeTypeAtReturn(w, &function.return_type, class, ctx);
            try w.writeLine(").?;");
        },
    }

    w.indent -= 1;
    try w.writeLine("}");

    // Method bind pointer storage
    if (class != null) {
        try w.printLine("var {0s}Alloc_ptr: std.atomic.Value(c.GDExtensionMethodBindPtr) = .init(null);", .{function.name});
    } else {
        try w.printLine("var {0s}Alloc_ptr: std.atomic.Value(c.GDExtensionPtrUtilityFunction) = .init(null);", .{function.name});
    }
}

fn writeClassFunctionObjectPtr(w: *CodeWriter, class: *const Context.Class, function: *const Context.Function, ctx: *const Context) !void {
    if (function.self == .static) {
        try w.writeAll("null");
    } else if (class.getNearestSingleton(ctx)) |singleton| {
        if (class.is_singleton) {
            try w.writeAll("@ptrCast(_singleton)");
        } else {
            try w.print("@ptrCast({s}.instance.load(.monotonic))", .{singleton.name});
        }
    } else if (function.self == .constant) {
        try w.writeAll("@ptrCast(@constCast(self))");
    } else {
        try w.writeAll("@ptrCast(self)");
    }
}

fn writeClassVirtualDispatch(w: *CodeWriter, class: *const Context.Class, ctx: *const Context) !void {
    _ = ctx;

    if (class.base) |base| {
        // Derived class - extend parent's VTable
        try w.printLine("pub const VTable = {s}.VTable.extend({s}, .{{", .{ base, class.name });

        w.indent += 1;
        for (class.functions.values()) |*function| {
            if (function.mode == .final) continue;
            try w.printLine("\"{s}\",", .{function.name});
        }
        w.indent -= 1;

        try w.writeLine("});");
    } else {
        // Root Object class - define the base VTable
        try w.printLine("pub const VTable = gdzig.class.VTable({s}, .{{", .{class.name});

        w.indent += 1;
        for (class.functions.values()) |*function| {
            if (function.mode == .final) continue;
            try w.printLine("\"{s}\",", .{function.name});
        }
        w.indent -= 1;

        try w.writeLine("});");
    }

    // Note: Virtual method implementations are not generated here.
    // The VTable uses comptime reflection on the user's type to find and wrap
    // the method implementations, so we only need to list the method names.
}

/// Emits named accessors for an *indexed* property, so the magic constant its
/// accessor takes is spelled out: `AreaLight3d.area_range` is `getParam(4)`, and
/// until now nothing in the Zig API said that 4 meant `.param_area_range`, nor
/// stopped you passing 5.
///
/// Only indexed properties get this. The 3,729 without an index already have
/// `getSyncMode`/`setSyncMode` generated from their accessor methods, so a
/// property declaration would be naming sugar over an identical call, and would
/// put ~4,000 more names into classes that collide often enough to need
/// `hasCollision`.
fn writeClassProperty(w: *CodeWriter, class: *const Context.Class, property: *const Context.Property, ctx: *const Context) !void {
    const index = property.index orelse return;

    // `AudioStreamPlaylist.stream_0` through `stream_63` are 64 properties over
    // one `getListStream(index)`. Generating an accessor apiece is noise, and
    // `getListStream(37)` already reads better than `getStream37()`. The filter
    // is the numeric suffix, not the sharing: `BaseMaterial3D.get_flag` backs 25
    // distinctly named properties and every one of them is worth an accessor.
    if (hasNumericSuffix(property.name_api)) return;

    const getter = class.functions.getPtr(property.getter.name_api) orelse return;
    if (getter.skip or getter.mode != .final) return;

    const getter_name = try accessorName(class, ctx, "get", property.name_api) orelse return;

    const getter_params = getter.parameters.values();
    if (getter_params.len != 1) return;
    const getter_index = enumMemberOf(&getter_params[0].type, @intCast(index), ctx) orelse return;

    try w.printLine("/// The `{0s}` property: `{1s}` with its index fixed to `.{2s}`.", .{
        property.name_api, getter.name, getter_index,
    });
    try w.print("pub fn {0s}(self: *const {1s}) ", .{ getter_name, class.name });
    try writeTypeAtReturn(w, &getter.return_type, class, ctx);
    try w.writeLine(" {");
    w.indent += 1;
    try w.printLine("return self.{0s}(.{1s});", .{ getter.name, getter_index });
    w.indent -= 1;
    try w.writeLine("}");
    try w.writeLine("");

    // Not every indexed property has a usable setter: the four `Control.anchor_*`
    // properties name `_set_anchor`, which is private and never generated.
    const setter_stub = property.setter orelse return;
    const setter = class.functions.getPtr(setter_stub.name_api) orelse return;
    if (setter.skip or setter.mode != .final) return;

    const setter_name = try accessorName(class, ctx, "set", property.name_api) orelse return;

    // Resolved from the setter's own parameter rather than reused from the
    // getter's, so a class whose two accessors disagree cannot silently get the
    // wrong constant.
    const setter_params = setter.parameters.values();
    if (setter_params.len != 2) return;
    const setter_index = enumMemberOf(&setter_params[0].type, @intCast(index), ctx) orelse return;

    try w.printLine("/// The `{0s}` property: `{1s}` with its index fixed to `.{2s}`.", .{
        property.name_api, setter.name, setter_index,
    });
    try w.print("pub fn {0s}(self: *{1s}, p_value: ", .{ setter_name, class.name });
    try writeTypeAtParameter(w, &setter_params[1].type, class, ctx);
    try w.writeLine(") void {");
    w.indent += 1;
    try w.printLine("self.{0s}(.{1s}, p_value);", .{ setter.name, setter_index });
    w.indent -= 1;
    try w.writeLine("}");
    try w.writeLine("");
}

/// `("get", "area_range")` -> `"getAreaRange"`, via the same conversion the
/// accessor methods themselves go through, so the two cannot drift apart.
///
/// Null when the class already has a method by that API name, in which case the
/// real method wins and no forwarder is emitted. No class in 4.7 hits this, but
/// the check is keyed on the API name rather than the converted one because
/// `class.functions` is: comparing a camelCase name against that map is a
/// mistake this codebase has made several times, and it fails silently.
fn accessorName(class: *const Context.Class, ctx: *const Context, comptime prefix: []const u8, name_api: []const u8) !?[]const u8 {
    const arena = ctx.arena.allocator();
    const joined = try std.fmt.allocPrint(arena, prefix ++ "_{s}", .{name_api});
    if (class.functions.contains(joined)) return null;
    return try casez.allocConvert(arena, gdzig_case.method, joined);
}

/// True for a name ending in `_` followed by digits, e.g. `stream_63`.
fn hasNumericSuffix(name: []const u8) bool {
    var i = name.len;
    while (i > 0 and std.ascii.isDigit(name[i - 1])) i -= 1;
    return i < name.len and i > 0 and name[i - 1] == '_';
}

/// The member name of `type` whose value is `value`, for use as a `.member`
/// literal. Null when the type is not an enum or has no such member.
fn enumMemberOf(@"type": *const Context.Type, value: i64, ctx: *const Context) ?[]const u8 {
    const api_name = switch (@"type".*) {
        .@"enum" => |name| name,
        else => return null,
    };

    const resolved: *const Context.Enum = blk: {
        if (std.mem.indexOfScalar(u8, api_name, '.')) |dot| {
            // Qualified, e.g. `Light3D.Param`. The owner may be an ancestor of
            // the class declaring the property, which the prefix names directly.
            const owner = ctx.classes.getPtr(api_name[0..dot]) orelse return null;
            break :blk owner.enums.getPtr(api_name[dot + 1 ..]) orelse return null;
        }
        break :blk ctx.enums.getPtr(api_name) orelse return null;
    };

    // First match wins. Godot aliases several names onto one value, and
    // `writeEnum` emits only the first as a tag; the rest become alias decls.
    for (resolved.values.values()) |member| {
        if (member.value == value) return member.name;
    }
    return null;
}

fn writeConstant(w: *CodeWriter, constant: *const Context.Constant, class: ?*const Context.Class, ctx: *const Context) !void {
    try writeDocBlock(w, constant.doc);
    try w.print("pub const {s}: ", .{constant.name});
    try writeTypeAtField(w, &constant.type, class, ctx);
    try w.printLine(" = {s};", .{constant.value});
}

fn writeDocBlock(w: *CodeWriter, docs: ?[]const u8) !void {
    if (docs) |d| {
        w.comment = .doc;
        try w.writeLine(d);
        w.comment = .off;
    }
}

/// Writes `native.zig`: the plain C structs the engine passes by pointer.
///
/// They are `extern struct` because the engine reads and writes them directly,
/// so the layout has to match the C declaration exactly. All of them appear
/// only in virtual methods an extension implements, which is why nothing
/// generated references them and they get a namespace of their own rather than
/// being threaded through the class imports.
fn writeNativeStructures(ctx: *const Context) !void {
    if (ctx.native_structures.count() == 0) return;

    var buf: [1024]u8 = undefined;
    const file = try ctx.config.output.createFile(ctx.config.io, "native.zig", .{});
    defer file.close(ctx.config.io);

    var file_writer = file.writer(ctx.config.io, &buf);
    var writer = &file_writer.interface;
    var w: CodeWriter = .init(writer);

    try w.writeLine(
        \\//! Native structures: plain C structs the engine passes by pointer.
        \\//!
        \\//! These appear in the signatures of virtual methods an extension
        \\//! implements, such as `AudioStreamPlayback._mix`.
        \\
    );

    var imports: Context.Imports = .empty;
    defer imports.deinit(ctx.rawAllocator());

    for (ctx.native_structures.values()) |*native| {
        try w.printLine("pub const {s} = extern struct {{", .{native.name});
        w.indent += 1;
        for (native.fields.items) |field| {
            if (field.default) |default| {
                try w.printLine("{s}: {s} = {s},", .{ field.name, field.type, default });
            } else {
                try w.printLine("{s}: {s},", .{ field.name, field.type });
            }
        }
        w.indent -= 1;
        try w.writeLine("};");
        try w.writeLine("");
    }

    try w.writeLine("const gdzig = @import(\"gdzig.zig\");");
    try writeNativeImports(&w, ctx);

    try writer.flush();
}

/// Emits an alias for every type the structures mention that is not a Zig
/// scalar or another native structure.
fn writeNativeImports(w: *CodeWriter, ctx: *const Context) !void {
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer seen.deinit(ctx.rawAllocator());

    // Keyed by API name (`ObjectID`), but field types carry the converted name
    // (`ObjectId`), so membership has to be tested against the converted set or
    // a structure ends up both declared here and imported from `class`.
    var declared: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer declared.deinit(ctx.rawAllocator());
    for (ctx.native_structures.values()) |*native| {
        try declared.put(ctx.rawAllocator(), native.name, {});
    }

    for (ctx.native_structures.values()) |*native| {
        for (native.fields.items) |field| {
            // Strip any `?*` or `[N]` wrapper down to the bare type name.
            var bare = field.type;
            if (std.mem.lastIndexOfScalar(u8, bare, ']')) |close| bare = bare[close + 1 ..];
            bare = std.mem.trimStart(u8, bare, "?*");
            // A qualified name like `TextServer.Direction` imports its owner.
            if (std.mem.indexOfScalar(u8, bare, '.')) |dot| bare = bare[0..dot];

            if (bare.len == 0 or std.ascii.isLower(bare[0])) continue; // scalar
            if (declared.contains(bare)) continue; // declared above
            if (seen.contains(bare)) continue;
            try seen.put(ctx.rawAllocator(), bare, {});
        }
    }

    // `builtins` is keyed by API name (`RID`) while these are converted (`Rid`),
    // so the namespace has to be decided against the converted spellings.
    var builtin_names: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer builtin_names.deinit(ctx.rawAllocator());
    for (ctx.builtins.values()) |*builtin| {
        try builtin_names.put(ctx.rawAllocator(), builtin.name, {});
    }

    for (seen.keys()) |name| {
        const namespace: []const u8 = if (builtin_names.contains(name)) "builtin" else "class";
        try w.printLine("const {0s} = gdzig.{1s}.{0s};", .{ name, namespace });
    }
}

fn writeGlobals(ctx: *const Context) !void {
    var buf: [1024]u8 = undefined;

    // global.zig
    {
        const file = try ctx.config.output.createFile(ctx.config.io, "global.zig", .{});
        defer file.close(ctx.config.io);

        var file_writer = file.writer(ctx.config.io, &buf);
        var writer = &file_writer.interface;
        var w = CodeWriter.init(writer);

        try writeMixin(&w, "global.mixin.zig", .{}, ctx);

        for (ctx.enums.values()) |@"enum"| {
            try w.printLine(
                \\pub const {1s} = @import("global/{0s}.zig").{1s};
            , .{ @"enum".module, @"enum".name });
        }

        try w.writeLine("");

        for (ctx.flags.values()) |flag| {
            try w.printLine(
                \\pub const {1s} = @import("global/{0s}.zig").{1s};
            , .{ flag.module, flag.name });
        }

        // `@GlobalScope` constants are plain scalars, so they are written here
        // directly rather than each getting a module of its own.
        if (ctx.global_constants.count() > 0) {
            try w.writeLine("");
            for (ctx.global_constants.values()) |*constant| {
                try writeConstant(&w, constant, null, ctx);
            }
        }

        // try w.writeLine(
        //     \\
        //     \\test {
        //     \\  @import("std").testing.refAllDecls(@This());
        //     \\}
        // );

        try writer.flush();
    }

    // global/[name].zig
    try ctx.config.output.createDirPath(ctx.config.io, "global");
    for (ctx.enums.values()) |*@"enum"| {
        const filename = try std.fmt.allocPrint(ctx.rawAllocator(), "global/{s}.zig", .{@"enum".module});
        defer ctx.rawAllocator().free(filename);

        const file = try ctx.config.output.createFile(ctx.config.io, filename, .{});
        defer file.close(ctx.config.io);

        var file_writer = file.writer(ctx.config.io, &buf);
        var writer = &file_writer.interface;
        var w = CodeWriter.init(writer);

        try writeEnum(&w, @"enum", ctx);

        try writer.flush();
    }

    for (ctx.flags.values()) |*flag| {
        const filename = try std.fmt.allocPrint(ctx.rawAllocator(), "global/{s}.zig", .{flag.module});
        defer ctx.rawAllocator().free(filename);

        const file = try ctx.config.output.createFile(ctx.config.io, filename, .{});
        defer file.close(ctx.config.io);

        var file_writer = file.writer(ctx.config.io, &buf);
        var writer = &file_writer.interface;
        var w = CodeWriter.init(writer);

        try writeFlag(&w, flag, ctx);

        try writer.flush();
    }
}

fn writeEnum(w: *CodeWriter, @"enum": *const Context.Enum, ctx: *const Context) !void {
    try writeDocBlock(w, @"enum".doc);
    try w.printLine("pub const {s} = enum(i32) {{", .{@"enum".name});
    w.indent += 1;

    // Godot enums sometimes alias multiple names onto the same value (e.g.
    // RenderingDevice.ShaderStage's *_BIT members, or DriverResource's
    // PHYSICAL_DEVICE/VULKAN_PHYSICAL_DEVICE pair). Zig enums can't have
    // duplicate tag values, so only the first-declared name per value (in
    // extension_api.json order) becomes a tag; later names sharing that
    // value are emitted as alias constants instead. Zig requires all
    // container fields before any decls, so alias entries are buffered
    // during this single pass over values and flushed as decls afterward.
    var seen: std.AutoArrayHashMapUnmanaged(i64, []const u8) = .empty;
    defer seen.deinit(ctx.rawAllocator());

    const Alias = struct { doc: ?[]const u8, name: []const u8, first_name: []const u8 };
    var aliases: std.ArrayList(Alias) = .empty;
    defer aliases.deinit(ctx.rawAllocator());

    for (@"enum".values.values()) |value| {
        if (seen.get(value.value)) |first_name| {
            try aliases.append(ctx.rawAllocator(), .{ .doc = value.doc, .name = value.name, .first_name = first_name });
        } else {
            try seen.put(ctx.rawAllocator(), value.value, value.name);

            try writeDocBlock(w, value.doc);
            try w.printLine("{s} = {d},", .{ value.name, value.value });
        }
    }

    for (aliases.items) |alias| {
        try writeDocBlock(w, alias.doc);
        try w.printLine("pub const {s}: @This() = .{s};", .{ alias.name, alias.first_name });
    }

    try writeMixin(w, "global/{s}.mixin.zig", .{@"enum".name}, ctx);
    w.indent -= 1;
    try w.writeLine("};");
}

fn writeField(w: *CodeWriter, field: *const Context.Field, class: ?*const Context.Class, ctx: *const Context) !void {
    try writeDocBlock(w, field.doc);
    try w.print("{s}: ", .{field.name});
    try writeTypeAtField(w, &field.type, class, ctx);
    try w.writeLine(
        \\,
        \\
    );
}

fn writeFlag(w: *CodeWriter, flag: *const Context.Flag, ctx: *const Context) !void {
    try writeDocBlock(w, flag.doc);
    try w.printLine("pub const {s} = packed struct({s}) {{", .{
        flag.name, flag.representation.name(),
    });
    w.indent += 1;
    for (flag.fields.values()) |field| {
        try writeDocBlock(w, field.doc);
        try w.printLine("{s}: bool = {s},", .{ field.name, if (field.default) "true" else "false" });
    }
    if (flag.padding > 0) {
        try w.printLine("_: u{d} = 0,", .{flag.padding});
    }
    for (flag.consts.values()) |@"const"| {
        try writeDocBlock(w, @"const".doc);
        try w.printLine("pub const {s}: {s} = @bitCast(@as({s}, {d}));", .{ @"const".name, flag.name, flag.representation.name(), @"const".value });
    }
    try writeMixin(w, "global/{s}.mixin.zig", .{flag.module}, ctx);
    w.indent -= 1;
    try w.writeLine("};");
}

fn writeFunctionHeader(w: *CodeWriter, function: *const Context.Function, class: ?*const Context.Class, ctx: *const Context) !void {
    if (function.is_vararg) {
        try w.writeLine(
            \\/// Guarantees no allocations when calling across the FFI. Passing Transform2d, Aabb, Basis, Transform3d, or Projection is a compile error; use the Alloc variant.
            \\///
        );
    }
    try writeDocBlock(w, function.doc);

    // Declaration
    try w.writeAll("");
    if (std.zig.Token.keywords.has(function.name)) {
        try w.print("pub fn @\"{s}\"(", .{function.name});
    } else {
        try w.print("pub fn {s}(", .{function.name});
    }

    var is_first = true;

    // Self parameter
    switch (function.self) {
        .static, .singleton => {},
        .constant => |api_name| {
            // Look up the converted name for the self type
            const name = if (ctx.classes.get(api_name)) |c| c.name else if (ctx.builtins.get(api_name)) |b| b.name else api_name;
            try w.print("self: *const {0s}", .{name});
            is_first = false;
        },
        .mutable => |api_name| {
            const name = if (ctx.classes.get(api_name)) |c| c.name else if (ctx.builtins.get(api_name)) |b| b.name else api_name;
            try w.print("self: *{0s}", .{name});
            is_first = false;
        },
        .value => |api_name| {
            const name = if (ctx.classes.get(api_name)) |c| c.name else if (ctx.builtins.get(api_name)) |b| b.name else api_name;
            try w.print("self: {0s}", .{name});
            is_first = false;
        },
    }

    // Positional parameters
    var opt: usize = function.parameters.count();
    for (function.parameters.values(), 0..) |param, i| {
        if (param.default != null) {
            opt = i;
            break;
        }
        if (!is_first) {
            try w.writeAll(", ");
        }
        try w.print("{s}: ", .{param.name});
        // For vararg functions, allocating types are passed as Variant
        if (function.is_vararg and param.type.allocatesAsVariant(ctx)) {
            try w.writeAll("Variant");
        } else {
            try writeTypeAtParameter(w, &param.type, class, ctx);
        }
        is_first = false;
    }

    // Variadic parameters
    if (function.is_vararg) {
        if (!is_first) {
            try w.writeAll(", ");
        }
        try w.writeAll("@\"...\": anytype");
        is_first = false;
    }

    // Optional parameters
    if (opt < function.parameters.count()) {
        if (!is_first) {
            try w.writeAll(", ");
        }
        try w.writeAll("opt: struct { ");
        is_first = true;
        for (function.parameters.values()[opt..]) |param| {
            if (!is_first) {
                try w.writeAll(", ");
            }
            try w.print("{s}: ", .{param.name});

            // Check if parameter needs runtime initialization
            if (param.needsRuntimeInit(ctx)) {
                // Use nullable type with null default for runtime-init params
                try w.writeAll("?");
                try writeTypeAtOptionalParameterField(w, &param.type, class, ctx);
                try w.writeAll(" = null");
            } else {
                if (param.default.?.isNullable()) {
                    try w.writeAll("?");
                }
                try writeTypeAtOptionalParameterField(w, &param.type, class, ctx);
                try w.writeAll(" = ");
                try writeValue(w, param.default.?, ctx);
            }
            is_first = false;
        }
        try w.writeAll(" }");
        is_first = false;
    }

    // Return type
    try w.writeAll(") ");
    try writeTypeAtReturn(w, &function.return_type, class, ctx);
    try w.writeLine(" {");
    w.indent += 1;

    // Parameter comptime type checking
    for (function.parameters.values()) |_| {
        // try generateFunctionParameterTypeCheck(w, param);
    }

    // Initialize runtime default values
    if (opt < function.parameters.count()) {
        for (function.parameters.values()[opt..]) |param| {
            if (param.needsRuntimeInit(ctx)) {
                try w.print("const actual_{s} = opt.{s} orelse ", .{ param.name, param.name });
                try writeValue(w, param.default.?, ctx);
                try w.writeLine(";");
            } else if (!function.is_vararg and function.operator_name == null and !function.can_init_directly) {
                if (optNullMaterializer(&param, ctx)) |init_expr| {
                    try w.print("var actual_{s}: ", .{param.name});
                    try writeTypeAtOptionalParameterField(w, &param.type, class, ctx);
                    try w.printLine(" = opt.{s} orelse {s};", .{ param.name, init_expr });
                    try w.printLine("defer if (opt.{0s} == null) actual_{0s}.deinit();", .{param.name});
                }
            }
        }
    }

    // Fixed argument slice variable
    if (!function.is_vararg and function.operator_name == null and !function.can_init_directly) {
        try w.printLine("var args: [{d}]c.GDExtensionConstTypePtr = undefined;", .{function.parameters.count()});
        for (function.parameters.values()[0..opt], 0..) |param, i| {
            try writeArgSlot(w, i, &param, null, class, ctx);
        }
        for (function.parameters.values()[opt..], opt..) |param, i| {
            const materialized = param.needsRuntimeInit(ctx) or optNullMaterializer(&param, ctx) != null;
            try writeArgSlot(w, i, &param, materialized, class, ctx);
        }
    }

    // Variadic argument handling
    if (function.is_vararg and function.operator_name == null) {
        const param_count = function.parameters.count();

        // Comptime verification that vararg types don't allocate
        try w.printLine(
            \\inline for (0..@"...".len) |_i| {{
            \\    if (comptime Variant.Tag.allocatesForType(@TypeOf(@"..."[_i]))) {{
            \\        @compileError(@typeName(@TypeOf(@"..."[_i])) ++ " allocates as Variant; use {s}Alloc() or pass a Variant instead.");
            \\    }}
            \\}}
        , .{function.name});

        // Build varargs array
        try w.writeLine("var _varargs: [@\"...\".len]Variant = undefined;");
        try w.writeLine("inline for (0..@\"...\".len) |_i| _varargs[_i] = Variant.init(@TypeOf(@\"...\"[_i]), @\"...\"[_i]);");
        try w.writeLine("defer for (&_varargs) |*v| v.deinit();");

        try w.printLine("var args: [{d} + @\"...\".len]c.GDExtensionConstTypePtr = undefined;", .{param_count});

        for (function.parameters.values()[0..opt], 0..) |param, i| {
            if (param.type == .variant or param.type.allocatesAsVariant(ctx)) {
                try w.printLine("args[{d}] = @ptrCast(&{s});", .{ i, param.name });
            } else {
                try w.print("args[{d}] = @ptrCast(&Variant.init(", .{i});
                try writeTypeAtParameter(w, &param.type, class, ctx);
                try w.printLine(", {s}));", .{param.name});
            }
        }
        for (function.parameters.values()[opt..], opt..) |param, i| {
            if (param.type == .variant or param.type.allocatesAsVariant(ctx)) {
                if (param.needsRuntimeInit(ctx)) {
                    try w.printLine("args[{d}] = @ptrCast(&actual_{s});", .{ i, param.name });
                } else {
                    try w.printLine("args[{d}] = @ptrCast(&opt.{s});", .{ i, param.name });
                }
            } else {
                if (param.needsRuntimeInit(ctx)) {
                    try w.print("args[{d}] = @ptrCast(&Variant.init(", .{i});
                    try writeTypeAtParameter(w, &param.type, class, ctx);
                    try w.printLine(", actual_{s}));", .{param.name});
                } else {
                    try w.print("args[{d}] = @ptrCast(&Variant.init(", .{i});
                    try writeTypeAtParameter(w, &param.type, class, ctx);
                    try w.printLine(", opt.{s}));", .{param.name});
                }
            }
        }

        try w.printLine("inline for (0..@\"...\".len) |_i| args[{d} + _i] = @ptrCast(&_varargs[_i]);", .{param_count});
    }

    // Return variable
    //
    // No vararg special case here, unlike the class-method writer above. A
    // class method with varargs goes through `object_method_bind_call`, which
    // really does hand back a Variant. A *builtin* method always ptrcalls, even
    // with varargs, and a ptrcall writes the native return type -- Godot's
    // `ptr_bind` encodes a `Callable` into `r_ret`. Declaring the slot as a
    // Variant let the engine write a `Callable` over it, after which
    // `result.as(Callable)` found an incompatible tag and returned null.
    if (function.return_type != .void) {
        {
            try w.writeAll("var result: ");
            if (function.return_type == .class) {
                try w.writeLine("?*anyopaque = null;");
            } else if (wideSlot(&function.return_type, ctx) != .none) {
                // Widen sub-8-byte scalar/enum/flag returns to an int64 slot so the engine's
                // 8-byte ptrcall write cannot overrun a narrow result; narrowed in the footer.
                try w.writeLine("i64 = 0;");
            } else {
                try writeTypeAtReturn(w, &function.return_type, class, ctx);
                const return_type_initializer = function.return_type.getDefaultInitializer(ctx);

                if (function.can_init_directly) {
                    try w.writeLine(" = undefined;");
                } else if (function.self != .static and return_type_initializer != null) {
                    try w.printLine(" = {s};", .{return_type_initializer.?});
                } else {
                    try w.writeAll(" = std.mem.zeroes(");
                    try writeTypeAtReturn(w, &function.return_type, class, ctx);
                    try w.writeLine(");");
                }
            }
        }
    }
}

/// For an optional parameter whose nullable default (empty String/Array/Dictionary/...)
/// maps to a by-value builtin, returns the initializer expression used to materialize a
/// real empty value at call time. Godot dereferences these builtins' internal pointers, so
/// a null/undefined optional payload passed as `&opt.name` is a dangling pointer -> segfault.
/// Returns null when the field is safe to pass by address as-is: object/raw pointers (a null
/// ptrcall slot is valid) and concrete-value defaults (non-nullable, already materialized).
fn optNullMaterializer(param: *const Context.Function.Parameter, ctx: *const Context) ?[]const u8 {
    if (param.default_materializer) |expr| return expr;
    if (param.needsRuntimeInit(ctx)) return null;
    const default = param.default orelse return null;
    if (!default.isNullable()) return null;
    return switch (param.type) {
        .array, .string, .string_name, .node_path => ".init()",
        .variant => ".nil",
        .basic => param.type.getDefaultInitializer(ctx) orelse ".init()",
        else => null, // .class, .pointer: a null ptrcall slot is a valid null object
    };
}

/// How a scalar/enum/flag must be marshalled through the ptrcall ABI, which passes every
/// integer and enum as int64 and every bitfield as int64 (godot-cpp method_ptrcall.h). A
/// sub-8-byte value needs a widened i64 temporary so the engine reads a full 8 bytes for an
/// argument (instead of over-reading adjacent stack) and writes a full 8 bytes into a return
/// slot (instead of over-writing memory past a narrow slot). Floats are already f64 in gdzig
/// and bool is 1 byte (matches uint8_t), so both marshal as `.none`.
///
/// This is the emission-side half of the ABI width rule; `src/class/ptrcall.zig` is the
/// runtime side, reading/writing the widened slots this function decides to emit.
const WideSlot = enum { none, int, @"enum", flag };

fn wideSlot(@"type": *const Context.Type, ctx: *const Context) WideSlot {
    return switch (@"type".*) {
        .int => |name| if (std.mem.eql(u8, name, "i64") or std.mem.eql(u8, name, "u64")) .none else .int,
        // Unconditional: writeEnum always emits `enum(i32)`, so no 64-bit enum exists to guard
        // against, unlike the .int/.flag arms above/below which check the representation width.
        .@"enum" => .@"enum",
        .flag => |api_name| if (std.mem.eql(u8, ctx.flagRepr(api_name), "u64")) .none else .flag,
        else => .none,
    };
}

/// Emits `args[i]`, widening sub-8-byte scalars/enums/flags into an int64 temporary whose
/// address is passed instead of the narrow value's. `materialized` selects the value
/// expression: `null` for a plain required parameter (`p_name`), `true`/`false` for an
/// optional parameter's runtime-materialized (`actual_name`) or as-passed (`opt.name`) form.
fn writeArgSlot(w: *CodeWriter, i: usize, param: *const Context.Function.Parameter, materialized: ?bool, class: ?*const Context.Class, ctx: *const Context) !void {
    var buf: [128]u8 = undefined;
    const src = if (materialized) |use_actual|
        try std.fmt.bufPrint(&buf, "{s}{s}", .{ if (use_actual) "actual_" else "opt.", param.name })
    else
        param.name;

    // A required class parameter arrives as `anytype`, so narrow it to the
    // declared base here. `upcast` is comptime-checked and names both types if
    // the argument is not a subclass. Optional class parameters keep their
    // concrete type -- they live in a struct, whose fields cannot be `anytype`
    // -- so they need no conversion.
    if (materialized == null and param.type == .class) {
        try w.print("const arg{d}_obj: ", .{i});
        try writeClassPointerType(w, param.type.class, class, ctx);
        try w.print(" = gdzig.class.upcast(", .{});
        try writeClassPointerType(w, param.type.class, class, ctx);
        try w.printLine(", {s});", .{src});
        try w.printLine("args[{d}] = @ptrCast(&arg{d}_obj);", .{ i, i });
        return;
    }

    switch (wideSlot(&param.type, ctx)) {
        .none => try w.printLine("args[{d}] = @ptrCast(&{s});", .{ i, src }),
        .int => {
            try w.printLine("const arg{d}_slot: i64 = @intCast({s});", .{ i, src });
            try w.printLine("args[{d}] = @ptrCast(&arg{d}_slot);", .{ i, i });
        },
        .@"enum" => {
            try w.printLine("const arg{d}_slot: i64 = @intFromEnum({s});", .{ i, src });
            try w.printLine("args[{d}] = @ptrCast(&arg{d}_slot);", .{ i, i });
        },
        .flag => {
            try w.printLine("const arg{d}_slot: i64 = @as({s}, @bitCast({s}));", .{ i, ctx.flagRepr(param.type.flag), src });
            try w.printLine("args[{d}] = @ptrCast(&arg{d}_slot);", .{ i, i });
        },
    }
}

fn writeValue(w: *CodeWriter, value: Context.Value, ctx: *const Context) !void {
    switch (value) {
        inline .null, .string => try w.writeAll("null"),
        .boolean => |b| try w.print("{}", .{b}),
        .primitive => |p| try w.writeAll(p),
        .constructor => |c| {
            const type_name = c.type.getName().?;
            const builtin = ctx.builtins.get(type_name) orelse std.debug.panic("Unsupported constructor: {s}", .{type_name});
            if (builtin.findConstructorByArgumentCount(c.args.len)) |function| {
                try w.print("{s}.{s}(", .{ builtin.name, function.name });

                for (c.args, 0..) |arg, i| {
                    const pval = Context.Constant.replacements.get(arg) orelse arg;

                    try w.writeAll(pval);

                    if (i != c.args.len - 1) {
                        try w.writeAll(", ");
                    }
                }
                try w.writeAll(")");
            } else {
                std.debug.panic("Unsupported constructor: {s}", .{type_name});
            }
        },
    }
}

fn writeFunctionFooter(w: *CodeWriter, function: *const Context.Function, class: ?*const Context.Class, ctx: *const Context) !void {
    switch (function.return_type) {
        // Class functions need to cast an object pointer. A refcounted one comes
        // back with the reference already taken on our behalf, so the handle
        // adopts it rather than taking a second.
        .class => |api_name| {
            if (ctx.isRefCounted(api_name)) {
                // `_ptr`, not `ptr`: classes carry a `ptr` mixin method that a
                // bare capture would shadow.
                try w.writeAll("return if (result) |_ptr| ");
                try w.writeAll("Gd(");
                try writeClassName(w, api_name, class, ctx);
                try w.writeLine(").adopt(@ptrCast(_ptr)) else null;");
            } else {
                try w.writeLine(
                    \\return @ptrCast(result);
                );
            }
        },

        // Variant return types can always be returned directly, even in a vararg function.
        .variant => {
            try w.writeLine(
                \\return result;
            );
        },

        // Void does nothing.
        .void => {},

        // The result slot is already the native return type, vararg or not.
        else => switch (wideSlot(&function.return_type, ctx)) {
            // Narrow the int64 result slot back to the declared sub-8-byte return type.
            .none => try w.writeLine("return result;"),
            .int => try w.writeLine("return @intCast(result);"),
            .@"enum" => try w.writeLine("return @enumFromInt(result);"),
            .flag => try w.printLine("return @bitCast(@as({s}, @intCast(result)));", .{ctx.flagRepr(function.return_type.flag)}),
        },
    }

    // End function
    w.indent -= 1;
    try w.writeLine("}");
}

fn writeImports(w: *CodeWriter, imports: *const Context.Imports, class: ?*const Context.Class, ctx: *const Context) !void {
    // std first
    try w.writeLine(
        \\
        \\const std = @import("std");
    );

    // Collect imports into separate lists for sorting
    var builtins: std.ArrayList([]const u8) = .empty;
    var classes: std.ArrayList([]const u8) = .empty;
    var globals: std.ArrayList([]const u8) = .empty;
    var typedefs: std.ArrayList([]const u8) = .empty;
    const allocator = ctx.arena.allocator();

    var iter = imports.iterator();
    while (iter.next()) |import| {
        if (util.isBuiltinType(import.*)) continue;

        // Skip the current type being defined (via imports.skip)
        if (imports.skip) |skip| {
            if (std.mem.eql(u8, import.*, skip)) continue;
        }

        if (std.mem.eql(u8, import.*, "Variant")) {
            try builtins.append(allocator, import.*);
        } else if (ctx.builtins.contains(import.*)) {
            try builtins.append(allocator, import.*);
        } else if (ctx.classes.contains(import.*)) {
            try classes.append(allocator, import.*);
        } else if (ctx.enums.contains(import.*)) {
            try globals.append(allocator, import.*);
        } else if (ctx.flags.contains(import.*)) {
            try globals.append(allocator, import.*);
        } else if (ctx.dispatch_table.typedefs.contains(import.*)) {
            try typedefs.append(allocator, import.*);
        } else {
            // TODO: native structures?
        }
    }

    // Sort each list alphabetically
    const sortFn = struct {
        fn cmp(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.cmp;

    std.mem.sort([]const u8, builtins.items, {}, sortFn);
    std.mem.sort([]const u8, classes.items, {}, sortFn);
    std.mem.sort([]const u8, globals.items, {}, sortFn);
    std.mem.sort([]const u8, typedefs.items, {}, sortFn);

    // c (gdextension)
    try w.writeLine(
        \\
        \\const c = @import("gdextension");
    );

    // Write sorted imports (typdefstogether under c)
    for (typedefs.items) |api_name| {
        // Note: We do not currently check for name collisions for interface typedefs.
        try w.printLine("const {0s} = c.{0s};", .{api_name});
    }

    // gdzig with all aliases
    try w.writeLine(
        \\
        \\const gdzig = @import("gdzig");
        \\const raw = &gdzig.raw;
        \\const Gd = gdzig.Gd;
    );

    // Write sorted imports (builtins, classes, globals all together under gdzig)
    // Note: import lists contain API names, but we need to use converted names
    // If a name collides with something in the current class, skip the const alias
    // and the code will use the fully qualified gdzig.class.X / gdzig.builtin.X path
    for (builtins.items) |api_name| {
        const name = if (ctx.builtins.get(api_name)) |b| b.name else api_name;
        // Check if this name collides with a signal/enum/flag in the class
        if (class) |c| {
            if (c.hasCollision(name)) continue;
        }
        try w.printLine("const {0s} = gdzig.builtin.{0s};", .{name});
    }
    for (classes.items) |api_name| {
        const name = if (ctx.classes.get(api_name)) |c| c.name else api_name;
        // Check if this name collides with a signal/enum/flag in the class
        if (class) |c| {
            if (c.hasCollision(name)) continue;
        }
        try w.printLine("const {0s} = gdzig.class.{0s};", .{name});
    }
    for (globals.items) |api_name| {
        const name = if (ctx.enums.get(api_name)) |e| e.name else if (ctx.flags.get(api_name)) |f| f.name else api_name;
        // Check if this name collides with a signal/enum/flag in the class
        if (class) |c| {
            if (c.hasCollision(name)) continue;
        }
        try w.printLine("const {0s} = gdzig.global.{0s};", .{name});
    }
}

/// Writes mixins for a class and all its parent classes.
/// Parent mixins are written first (from root to leaf), so child classes
/// can override or extend parent mixin functionality.
fn writeClassMixins(w: *CodeWriter, class: *const Context.Class, ctx: *const Context) !void {
    // Recurse to parent first (writes from root to leaf)
    if (class.getBasePtr(ctx)) |parent| {
        try writeClassMixins(w, parent, ctx);
    }
    try writeMixin(w, "class/{s}.mixin.zig", .{class.name}, ctx);
}

fn writeMixin(w: *CodeWriter, comptime fmt: []const u8, args: anytype, ctx: *const Context) !void {
    const filename = try std.fmt.allocPrint(ctx.arena.allocator(), fmt, args);
    const file: ?std.Io.File = ctx.config.input.openFile(ctx.config.io, filename, .{}) catch null;
    if (file) |f| {
        defer f.close(ctx.config.io);

        var buf: [1024]u8 = undefined;
        var file_reader = f.reader(ctx.config.io, &buf);
        var reader = &file_reader.interface;

        // Skip lines until we find @mixin start (or copy from beginning if not found)
        var found_start = false;
        while (true) {
            const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };

            if (std.mem.startsWith(u8, line, "// @mixin start")) {
                found_start = true;
                break;
            }
        }

        // If no @mixin start found, reopen file to read from beginning
        if (!found_start) {
            file_reader.seekTo(0) catch return;
        }

        // Copy lines until we find @mixin stop
        while (true) {
            const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };

            if (std.mem.startsWith(u8, line, "// @mixin stop")) {
                break;
            }

            try w.writeAll(line);
        }
    }
}

fn writeDispatchTable(ctx: *Context) !void {
    var buf: [1024]u8 = undefined;

    const file = try ctx.config.output.createFile(ctx.config.io, "DispatchTable.zig", .{});
    defer file.close(ctx.config.io);

    var file_writer = file.writer(ctx.config.io, &buf);
    var writer = &file_writer.interface;
    var w = CodeWriter.init(writer);

    try w.writeLine(
        \\const DispatchTable = @This();
        \\
    );
    try w.writeLine(
        \\library: Child(c.GDExtensionClassLibraryPtr),
        \\
    );

    // Functions present since 4.1 are non-nullable; everything newer is
    // nullable. Targeting 4.7 only, every one of these is in fact available, so
    // it is tempting to make them all non-nullable and drop the unwrapping.
    //
    // Don't. `DispatchTable.init` resolves the non-nullable ones with `.?`, and
    // it runs before the entrypoint can compare versions. Marking everything
    // required turns "loaded into an engine older than 4.7" from a clear
    // diagnostic into a panic inside init, before anything can report why.
    // The 4.1 subset is the set that is safe to assume while still being able
    // to talk about it.
    for (ctx.dispatch_table.functions.items) |function| {
        try writeDocBlock(&w, function.docs);
        if (function.isRequired()) {
            try w.printLine(
                \\{s}: Child(c.{s}),
                \\
            , .{ function.name, function.ptr_type });
        } else {
            try w.printLine(
                \\{s}: c.{s},
                \\
            , .{ function.name, function.ptr_type });
        }
    }

    // Write init function
    try w.writeLine("pub fn init(getProcAddress: Child(c.GDExtensionInterfaceGetProcAddress), library: Child(c.GDExtensionClassLibraryPtr)) DispatchTable {");
    w.indent += 1;

    try w.writeLine(
        \\return .{
        \\    .library = library,
    );
    w.indent += 1;

    for (ctx.dispatch_table.functions.items) |function| {
        if (function.isRequired()) {
            try w.printLine(
                \\.{s} = @ptrCast(getProcAddress("{s}").?),
            , .{ function.name, function.api_name });
        } else {
            try w.printLine(
                \\.{s} = @ptrCast(getProcAddress("{s}")),
            , .{ function.name, function.api_name });
        }
    }

    w.indent -= 1;
    try w.writeLine(
        \\};
    );

    w.indent -= 1;
    try w.writeLine(
        \\}
        \\
    );

    try w.writeLine(
        \\const std = @import("std");
        \\const Child = std.meta.Child;
        \\
        \\const c = @import("gdextension");
        \\
        \\const builtin = @import("builtin.zig");
        \\const class = @import("class.zig");
        \\const global = @import("global.zig");
    );

    try writer.flush();
    try file.sync(ctx.config.io);
}

fn writeModules(ctx: *const Context) !void {
    var buf: [1024]u8 = undefined;

    for (ctx.modules.values()) |*module| {
        const filename = try std.fmt.allocPrint(ctx.rawAllocator(), "{s}.zig", .{module.name});
        defer ctx.rawAllocator().free(filename);

        const file = try ctx.config.output.createFile(ctx.config.io, filename, .{});
        defer file.close(ctx.config.io);

        var file_writer = file.writer(ctx.config.io, &buf);
        var writer = &file_writer.interface;
        var w = CodeWriter.init(writer);

        try writeModule(&w, module, ctx);

        try writer.flush();
    }
}

fn writeModule(w: *CodeWriter, module: *const Context.Module, ctx: *const Context) !void {
    try writeMixin(w, "{s}.mixin.zig", .{module.name}, ctx);

    for (module.functions) |*function| {
        if (function.skip) continue;

        try writeModuleFunction(w, function, ctx);

        // Write allocating wrapper for vararg functions
        if (function.is_vararg) {
            try writeFunctionAlloc(w, function, null, ctx);
        }
    }
    try writeImports(w, &module.imports, null, ctx);
}

fn writeModuleFunction(w: *CodeWriter, function: *const Context.Function, ctx: *const Context) !void {
    // For vararg functions, generate a thin wrapper that does comptime check + delegates to Alloc version
    if (function.is_vararg) {
        try writeModuleFunctionVarargWrapper(w, function, ctx);
        return;
    }

    try writeFunctionHeader(w, function, null, ctx);

    try w.printLine(
        \\var _bind = {0s}_ptr.load(.monotonic);
        \\if (_bind == null) {{
        \\    _bind = raw.variantGetPtrUtilityFunction(@ptrCast(@constCast(StringName.fromComptimeLatin1("{1s}"))), {2d});
        \\    {0s}_ptr.store(_bind, .monotonic);
        \\}}
        \\_bind.?({3s}, @ptrCast(&args), @intCast(args.len));
    , .{
        function.name,
        function.name_api,
        function.hash.?,
        if (function.return_type != .void) "@ptrCast(&result)" else "null",
    });
    try writeFunctionFooter(w, function, null, ctx);
    try w.printLine(
        \\var {0s}_ptr: std.atomic.Value(c.GDExtensionPtrUtilityFunction) = .init(null);
        \\
    , .{function.name});
}

/// Writes a thin vararg wrapper for a module function that does comptime check and delegates to the Alloc version.
fn writeModuleFunctionVarargWrapper(w: *CodeWriter, function: *const Context.Function, ctx: *const Context) !void {
    try w.writeLine(
        \\/// Guarantees no allocations when calling across the FFI. Passing packed arrays is a compile error; use the Alloc variant.
        \\///
    );
    try writeDocBlock(w, function.doc);

    // Function signature
    if (std.zig.Token.keywords.has(function.name)) {
        try w.print("pub fn @\"{s}\"(", .{function.name});
    } else {
        try w.print("pub fn {s}(", .{function.name});
    }

    var is_first = true;
    for (function.parameters.values()) |param| {
        if (!is_first) try w.writeAll(", ");
        try w.print("{s}: ", .{param.name});
        try writeTypeAtParameter(w, &param.type, null, ctx);
        is_first = false;
    }

    if (!is_first) try w.writeAll(", ");
    try w.writeAll("@\"...\": anytype) ");
    try writeTypeAtReturn(w, &function.return_type, null, ctx);
    try w.writeLine(" {");
    w.indent += 1;

    // Comptime check - skip Variant type (already a Variant, no wrapping needed)
    try w.printLine(
        \\inline for (0..@"...".len) |_i| {{
        \\    if (@TypeOf(@"..."[_i]) != Variant and comptime Variant.Tag.allocatesForType(@TypeOf(@"..."[_i]))) {{
        \\        @compileError(@typeName(@TypeOf(@"..."[_i])) ++ " requires allocation; use {s}Alloc() or pass a Variant instead.");
        \\    }}
        \\}}
    , .{function.name});

    // Delegate to Alloc version
    if (function.return_type != .void) {
        try w.writeAll("return ");
    }

    try w.print("{s}Alloc(", .{function.name});

    is_first = true;
    for (function.parameters.values()) |param| {
        if (!is_first) try w.writeAll(", ");
        try w.print("{s}", .{param.name});
        is_first = false;
    }

    if (!is_first) try w.writeAll(", ");
    try w.writeLine("@\"...\");");

    w.indent -= 1;
    try w.writeLine("}");
}

/// Converts a possibly qualified type name (e.g., "AStarGrid2D.CellShape") to use converted class prefixes.
/// For qualified names, splits on "." and converts the class prefix.
/// For simple names, looks them up in the appropriate ctx map (enums or flags).
/// Enums whose generated spelling differs from the API's because the owning
/// type is hand-written rather than generated.
///
/// `Variant` lives in `src/builtin/variant.zig` and calls its type tag `Tag`,
/// which is why `Context.castEnums` skips `Variant.*`. Nothing generates the
/// enum, so references to it have to be redirected here.
const renamed_qualified_enums = std.StaticStringMap([]const u8).initComptime(.{
    .{ "Variant.Type", "Variant.Tag" },
});

fn convertQualifiedName(api_name: []const u8, ctx: *const Context, comptime map_type: enum { enums, flags }) []const u8 {
    if (renamed_qualified_enums.get(api_name)) |renamed| return renamed;

    // Check if it's a qualified name (contains a dot)
    if (std.mem.indexOf(u8, api_name, ".")) |dot_idx| {
        const class_api_name = api_name[0..dot_idx];
        const member_api_name = api_name[dot_idx + 1 ..];
        // Look up the class to get its converted name
        if (ctx.classes.get(class_api_name)) |class| {
            // Both halves need converting. The member is declared under its
            // converted name, so emitting the API spelling produces references
            // to something that does not exist -- visible only on names whose
            // case actually changes, which is the ones carrying acronyms
            // (`GIMode` -> `GiMode`, `MSAA` -> `Msaa`).
            const member_name = switch (map_type) {
                .enums => if (class.enums.get(member_api_name)) |e| e.name else member_api_name,
                .flags => if (class.flags.get(member_api_name)) |f| f.name else member_api_name,
            };
            // We need to allocate, but can use the arena
            return std.fmt.allocPrint(ctx.arena.allocator(), "{s}.{s}", .{ class.name, member_name }) catch api_name;
        }
        // Fallback to original if class not found
        return api_name;
    }

    // Not qualified, look up in the appropriate map
    return switch (map_type) {
        .enums => if (ctx.enums.get(api_name)) |e| e.name else api_name,
        .flags => if (ctx.flags.get(api_name)) |f| f.name else api_name,
    };
}

fn writeTypeAtField(w: *CodeWriter, @"type": *const Context.Type, class: ?*const Context.Class, ctx: *const Context) !void {
    switch (@"type".*) {
        .array => try w.writeAll("Array"),
        .class => |api_name| {
            const name = if (ctx.classes.get(api_name)) |c| c.name else api_name;
            if (class) |cl| if (cl.hasCollision(name)) {
                try w.print("*gdzig.class.{0s}", .{name});
                return;
            };
            try w.print("*{0s}", .{name});
        },
        .node_path => try w.writeAll("NodePath"),
        .pointer => |child| {
            try w.writeAll("*");
            try writeTypeAtField(w, child, class, ctx);
        },
        .string => try w.writeAll("String"),
        .string_name => try w.writeAll("StringName"),
        .@"union" => @panic("cannot format a union types in a struct field position"),
        .variant => try w.writeAll("Variant"),
        .void => try w.writeAll("void"),
        .basic => |api_name| {
            const name = if (ctx.builtins.get(api_name)) |b| b.name else api_name;
            if (class) |cl| if (cl.hasCollision(name)) {
                try w.print("gdzig.builtin.{0s}", .{name});
                return;
            };
            try w.writeAll(name);
        },
        .@"enum" => |api_name| {
            const name = convertQualifiedName(api_name, ctx, .enums);
            if (class) |cl| if (cl.hasCollision(name)) {
                try w.print("gdzig.global.{0s}", .{name});
                return;
            };
            try w.writeAll(name);
        },
        .flag => |api_name| {
            const name = convertQualifiedName(api_name, ctx, .flags);
            if (class) |cl| if (cl.hasCollision(name)) {
                try w.print("gdzig.global.{0s}", .{name});
                return;
            };
            try w.writeAll(name);
        },
        inline else => |s| try w.writeAll(s),
    }
}

/// Writes the name a class is referred to by from inside `class`: the short
/// alias normally, or the fully qualified path when the alias would collide
/// with a member of the enclosing class and so was never emitted.
fn writeClassName(w: *CodeWriter, api_name: []const u8, class: ?*const Context.Class, ctx: *const Context) !void {
    const name = if (ctx.classes.get(api_name)) |c| c.name else api_name;
    if (class) |cl| if (cl.hasCollision(name)) {
        try w.print("gdzig.class.{0s}", .{name});
        return;
    };
    try w.writeAll(name);
}

fn writeTypeAtReturn(w: *CodeWriter, @"type": *const Context.Type, class: ?*const Context.Class, ctx: *const Context) !void {
    switch (@"type".*) {
        .array => try w.writeAll("Array"),
        .class => |api_name| {
            // A refcounted return arrives with the count already incremented, so
            // the caller owns it; say so in the signature with an owning handle.
            // Everything else is a plain borrowed pointer.
            if (ctx.isRefCounted(api_name)) {
                try w.writeAll("?Gd(");
                try writeClassName(w, api_name, class, ctx);
                try w.writeAll(")");
            } else {
                try w.writeAll("?*");
                try writeClassName(w, api_name, class, ctx);
            }
        },
        .node_path => try w.writeAll("NodePath"),
        .pointer => |child| {
            try w.writeAll("*");
            try writeTypeAtField(w, child, class, ctx);
        },
        .string => try w.writeAll("String"),
        .string_name => try w.writeAll("StringName"),
        .@"union" => @panic("cannot format a union type in a return position"),
        .variant => try w.writeAll("Variant"),
        .void => try w.writeAll("void"),
        .basic => |api_name| {
            const name = if (ctx.builtins.get(api_name)) |b| b.name else api_name;
            if (class) |cl| if (cl.hasCollision(name)) {
                try w.print("gdzig.builtin.{0s}", .{name});
                return;
            };
            try w.writeAll(name);
        },
        .@"enum" => |api_name| {
            const name = convertQualifiedName(api_name, ctx, .enums);
            if (class) |cl| if (cl.hasCollision(name)) {
                try w.print("gdzig.global.{0s}", .{name});
                return;
            };
            try w.writeAll(name);
        },
        .flag => |api_name| {
            const name = convertQualifiedName(api_name, ctx, .flags);
            if (class) |cl| if (cl.hasCollision(name)) {
                try w.print("gdzig.global.{0s}", .{name});
                return;
            };
            try w.writeAll(name);
        },
        inline else => |s| try w.writeAll(s),
    }
}

/// Writes out a Type for a function parameter. Used to provide `anytype` where we do comptime type
/// checks and coercions.
/// The concrete `*Class` a parameter accepts, which its signature no longer
/// states. Used by the body's upcast and by the generated surface
/// instantiations.
fn writeClassPointerType(w: *CodeWriter, api_name: []const u8, class: ?*const Context.Class, ctx: *const Context) !void {
    const name = if (ctx.classes.get(api_name)) |c| c.name else api_name;
    if (class) |cl| if (cl.hasCollision(name)) {
        try w.print("*gdzig.class.{0s}", .{name});
        return;
    };
    try w.print("*{0s}", .{name});
}

fn writeTypeAtParameter(w: *CodeWriter, @"type": *const Context.Type, class: ?*const Context.Class, ctx: *const Context) !void {
    switch (@"type".*) {
        .array => try w.writeAll("Array"),
        // `anytype` so a subclass can be passed without the caller writing an
        // upcast: Zig has no implicit pointer conversion between distinct
        // struct types, and no way to spell "pointer to any subclass of Node"
        // as a concrete type. The body upcasts, which is where the base class
        // is enforced and named in the error.
        .class => try w.writeAll("anytype"),
        .node_path => try w.writeAll("NodePath"),
        .pointer => |child| {
            try w.writeAll("*");
            try writeTypeAtField(w, child, class, ctx);
        },
        .string => try w.writeAll("String"),
        .string_name => try w.writeAll("StringName"),
        .@"union" => @panic("cannot format a union type in a function parameter position"),
        .variant => try w.writeAll("Variant"),
        .void => try w.writeAll("void"),
        .basic => |api_name| {
            const name = if (ctx.builtins.get(api_name)) |b| b.name else api_name;
            if (class) |cl| if (cl.hasCollision(name)) {
                try w.print("gdzig.builtin.{0s}", .{name});
                return;
            };
            try w.writeAll(name);
        },
        .@"enum" => |api_name| {
            const name = convertQualifiedName(api_name, ctx, .enums);
            if (class) |cl| if (cl.hasCollision(name)) {
                try w.print("gdzig.global.{0s}", .{name});
                return;
            };
            try w.writeAll(name);
        },
        .flag => |api_name| {
            const name = convertQualifiedName(api_name, ctx, .flags);
            if (class) |cl| if (cl.hasCollision(name)) {
                try w.print("gdzig.global.{0s}", .{name});
                return;
            };
            try w.writeAll(name);
        },
        inline else => |s| try w.writeAll(s),
    }
}

/// Writes out a Type for a function parameter. Used to provide `anytype` where we do comptime type
/// checks and coercions.
fn writeTypeAtOptionalParameterField(w: *CodeWriter, @"type": *const Context.Type, class: ?*const Context.Class, ctx: *const Context) !void {
    switch (@"type".*) {
        .array => try w.writeAll("Array"),
        .class => |api_name| {
            const name = if (ctx.classes.get(api_name)) |c| c.name else api_name;
            if (class) |cl| if (cl.hasCollision(name)) {
                try w.print("*gdzig.class.{0s}", .{name});
                return;
            };
            try w.print("*{0s}", .{name});
        },
        .node_path => try w.writeAll("NodePath"),
        .pointer => |child| {
            try w.writeAll("*");
            try writeTypeAtField(w, child, class, ctx);
        },
        .string => try w.writeAll("String"),
        .string_name => try w.writeAll("StringName"),
        .@"union" => @panic("cannot format a union type in a function parameter position"),
        .variant => try w.writeAll("Variant"),
        .void => try w.writeAll("void"),
        .basic => |api_name| {
            const name = if (ctx.builtins.get(api_name)) |b| b.name else api_name;
            if (class) |cl| if (cl.hasCollision(name)) {
                try w.print("gdzig.builtin.{0s}", .{name});
                return;
            };
            try w.writeAll(name);
        },
        .@"enum" => |api_name| {
            const name = convertQualifiedName(api_name, ctx, .enums);
            if (class) |cl| if (cl.hasCollision(name)) {
                try w.print("gdzig.global.{0s}", .{name});
                return;
            };
            try w.writeAll(name);
        },
        .flag => |api_name| {
            const name = convertQualifiedName(api_name, ctx, .flags);
            if (class) |cl| if (cl.hasCollision(name)) {
                try w.print("gdzig.global.{0s}", .{name});
                return;
            };
            try w.writeAll(name);
        },
        inline else => |s| try w.writeAll(s),
    }
}

const std = @import("std");

const casez = @import("casez");
const common = @import("common");
const gdzig_case = common.gdzig_case;

const CodeWriter = @import("CodeWriter.zig");
const Context = @import("Context.zig");
const util = @import("util.zig");
