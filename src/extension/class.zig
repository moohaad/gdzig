pub fn registerClass(comptime T: type, info: ClassInfo4(ClassUserdataOf(T))) void {
    const class_name = StringName.fromType(T);
    const base_name = StringName.fromType(class.BaseOf(T));
    const callbacks = comptime makeClassCallbacks(T);
    const Userdata = ClassUserdataOf(T);

    // gdzig targets Godot 4.7, so only the newest registration entry point is
    // reachable. `registerClass1` through `registerClass3` remain available in
    // `ClassDb.mixin.zig` as bindings to the corresponding engine functions.
    classdb.registerClass4(T, Userdata, void, class_name, base_name, if (Userdata != void) .{
        .userdata = info.userdata,
        .is_virtual = info.is_virtual,
        .is_abstract = info.is_abstract,
        .is_exposed = info.is_exposed,
        .is_runtime = info.is_runtime,
    } else .{
        .is_virtual = info.is_virtual,
        .is_abstract = info.is_abstract,
        .is_exposed = info.is_exposed,
        .is_runtime = info.is_runtime,
    }, callbacks);
}

/// Extracts the `ClassUserdata` type from a type `T` by inspecting its `create` function.
pub fn ClassUserdataOf(comptime T: type) type {
    if (!@hasDecl(T, "create")) {
        if (!canSynthesize(T)) @compileError(synthesisHelp(T, "create"));
        // The synthesized lifecycle takes the allocator it will later free the
        // instance with, which is the shape a hand-written `create` uses too.
        return *Allocator;
    }
    const params = @typeInfo(@TypeOf(T.create)).@"fn".params;
    return switch (params.len) {
        0 => void,
        1 => params[0].type.?,
        inline else => @compileError("Type '" ++ @typeName(T) ++ "'.create must take zero or one parameters"),
    };
}

/// Whether gdzig can write `create`, `recreate` and `destroy` for `T`.
///
/// The conventional class keeps the allocator it was made with and a pointer to
/// its engine object, which is everything those three need. A class shaped
/// differently writes its own.
fn canSynthesize(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasField(T, "allocator") and @hasField(T, "base");
}

fn synthesisHelp(comptime T: type, comptime what: []const u8) []const u8 {
    return "Type '" ++ @typeName(T) ++ "' needs a '" ++ what ++
        "' function, or an `allocator` and a `base` field so gdzig can write one";
}

/// The engine object for a registered class's `base` field.
///
/// `base` must be a plain pointer for oopz to recognise the struct as a class,
/// and for a plain class `Base.init()` is exactly that. For a **refcounted**
/// base it is not, and the difference leaks:
///
/// `Base.init()` calls `init_ref`, which spends the compensation Godot arms on
/// a freshly constructed object. The instance then goes straight back to the
/// engine, which wraps it in its own `Ref` -- whose `init_ref` finds nothing
/// left to compensate and increments to 2. Nothing ever drops the second, the
/// object never reaches zero, and its `destroy` never runs. Measured: one
/// `Resource` retained at exit for every registered refcounted class the engine
/// instantiates, with the refcount reading 1 the moment `create` returned.
///
/// Constructing without referencing leaves the compensation armed, so the
/// engine's `Ref` settles at 1 and owns it alone.
///
/// This is only right for an object handed straight to Godot. Code making a
/// resource *for itself* still wants `Base.init()` and the handle it returns.
pub fn baseForEngine(comptime Base: type) *Base {
    const counted = comptime gd.isGd(@typeInfo(@TypeOf(Base.init)).@"fn".return_type.?);
    if (comptime !counted) return Base.init();
    return @ptrCast(gdzig.raw.classdbConstructObject(@ptrCast(StringName.fromType(Base))).?);
}

/// The lifecycle a class does not have to spell out.
///
/// The same three functions in every class: allocate, point at the engine
/// object, bind the two together, and undo it. Declaring any of them on the
/// class overrides the one here, so a class with something to release still
/// writes its own `destroy`.
///
/// Fields other than `allocator` and `base` must have defaults, since these
/// initialise the struct wholesale. A field that cannot default produces a
/// "missing struct field" error pointing at `create` below, and wants a
/// hand-written one instead.
fn Synthesized(comptime T: type) type {
    return struct {
        const Base = EngineBaseOf(T);

        /// Whether the base is reference counted, asked the way that matters
        /// rather than by walking ancestry: a refcounted constructor hands back
        /// an owning `Gd(Base)`, a plain one hands back the pointer.
        const base_is_counted = gd.isGd(@typeInfo(@TypeOf(Base.init)).@"fn".return_type.?);

        fn create(allocator: *Allocator) !*T {
            const self = try allocator.create(T);
            self.* = initChain(T, allocator, baseForEngine(Base));
            engineObject(self).setInstance(T, self);
            return self;
        }

        /// Reload's half: the engine object outlives the library, so this
        /// adopts the surviving one rather than making another.
        fn recreate(allocator: *Allocator, obj: *Object) *T {
            const self = allocator.create(T) catch @panic("OOM");
            self.* = initChain(T, allocator, @as(*Base, @ptrCast(obj)));
            engineObject(self).setInstance(T, self);
            return self;
        }

        fn destroy(self: *T, allocator: *Allocator) void {
            // A reference counted object goes when its last reference does.
            // Destroying one here would be freeing something the engine is
            // still counting, which is why a `Resource`-based class writes
            // `allocator.destroy(self)` and nothing else.
            if (comptime !base_is_counted) engineObject(self).destroy();
            allocator.destroy(self);
        }

        /// `upcast`, because `self.base` is only the engine object when the
        /// base is a pointer. A derived user class embeds its parent, and the
        /// object is at the bottom of that chain.
        inline fn engineObject(self: *T) *Base {
            return class.upcast(*Base, self);
        }
    };
}

/// The nearest engine class above `T`, skipping any user classes in between.
///
/// `T.base` names the *declared* parent, which for a derived user class is
/// another struct. What the lifecycle needs is the opaque class at the bottom:
/// that is what `init`s, what carries `setInstance`, and what `destroy` frees.
fn EngineBaseOf(comptime T: type) type {
    comptime var Current = class.BaseOf(T);
    inline while (@typeInfo(Current) == .@"struct") Current = class.BaseOf(Current);
    return Current;
}

/// Builds `S` and every user class it embeds, with the engine object at the
/// bottom of the chain.
///
/// A pointer base is the last level, and a struct base recurses. Every level
/// needs its own `allocator`, since each is initialised whole here.
fn initChain(comptime S: type, allocator: *Allocator, obj: anytype) S {
    if (comptime !@hasField(S, "allocator")) @compileError(
        "gdzig is synthesizing a lifecycle that has to initialise '" ++ @typeName(S) ++
            "', an embedded base, but it has no `allocator` field. Give it one, or write `create` yourself.",
    );
    const BaseField = @FieldType(S, "base");
    if (comptime class.isClassPtr(BaseField)) {
        return .{ .allocator = allocator.*, .base = @ptrCast(obj) };
    }
    return .{ .allocator = allocator.*, .base = initChain(BaseField, allocator, obj) };
}

/// Whether dispatches are counted so that freeing an object out from under one
/// can be caught. Enabled where the other safety checks are.
pub const track_dispatch = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

/// What a user class's instance actually is, so a narrowing cast can be checked
/// rather than assumed.
///
/// The engine cannot answer this. `objectSetInstance` does not make
/// `object_get_class_name` report the extension class for an object gdzig built
/// itself, `classdb_get_classtag` returns null for an extension class, and
/// `set_instance_binding` takes one binding per object so the ancestors cannot
/// each have their own token. gdzig therefore records it, on the per-object
/// record it already keeps.
pub const InstanceType = struct {
    /// Unique per class: the address of a per-`T` static, so identity is a
    /// pointer comparison and needs no names or hashing.
    id: *const anyopaque,
    /// Narrows a stored instance to the class `target` identifies, or null if
    /// the instance is not one. Generated per concrete class, so the walk is
    /// the real `upcast` chain rather than a reinterpretation.
    narrow: *const fn (instance: *anyopaque, target: *const anyopaque) ?*anyopaque,
};

/// The descriptor for `T`, one static per class.
pub fn instanceTypeOf(comptime T: type) *const InstanceType {
    return &struct {
        var marker: u8 = 0;

        const info: InstanceType = .{ .id = &marker, .narrow = narrow };

        fn narrow(instance: *anyopaque, target: *const anyopaque) ?*anyopaque {
            // `upcast` walks the whole base chain for a struct class, and the
            // default quota runs out mid-walk -- the same reason `Weak.init`
            // raises it.
            @setEvalBranchQuota(10_000);
            const self: *T = @ptrCast(@alignCast(instance));
            inline for (comptime class.selfAndAncestorsOf(T)) |Ancestor| {
                if (comptime class.isStructClass(Ancestor)) {
                    if (target == instanceTypeOf(Ancestor).id) {
                        // `upcast`, not a cast: for an embedded base the
                        // ancestor lives at `&self.base`, which is only the
                        // same address when the layout happens to put it first.
                        return @ptrCast(class.upcast(*Ancestor, self));
                    }
                }
            }
            return null;
        }
    }.info;
}

/// Tracks destruction state to prevent double-free, and what the instance is.
pub const DestroyInstanceBinding = struct {
    user_destroying: bool = false,
    engine_destroying: bool = false,
    /// The concrete user class this object's instance is, set by
    /// `Object.setInstance`. Null for an engine object that never had one.
    instance_type: ?*const InstanceType = null,
    /// How many gdzig dispatches -- bound methods and virtual overrides -- are
    /// currently executing on this instance. Freeing the object while this is
    /// non-zero means the dispatch is about to return into freed memory.
    ///
    /// Atomic because Godot dispatches from whichever thread makes the call; a
    /// torn counter would turn a debugging aid into a source of false panics.
    dispatch_depth: std.atomic.Value(u16) = .init(0),

    var gpa: GeneralPurposeAllocator = .init;
    const allocator = gpa.allocator();
    var pool: MemoryPool(DestroyInstanceBinding) = .empty;

    /// Guards `pool` and `gpa`, neither of which locks. Godot creates and frees
    /// instance bindings from whichever thread touches or drops the object, so
    /// two concurrent frees would corrupt the pool's free list.
    ///
    /// A spin lock rather than a blocking one because Zig 0.16 has no io-free
    /// blocking mutex: `std.Io.Mutex` wants an `Io`, which a shared library with
    /// no `main` does not have, and `std.atomic.Mutex` is try-only. The critical
    /// section is a pool alloc or free, so spinning is the right trade anyway.
    var pool_lock: std.atomic.Mutex = .unlocked;

    fn lockPool() void {
        while (!pool_lock.tryLock()) std.atomic.spinLoopHint();
    }

    pub const callbacks: c.GDExtensionInstanceBindingCallbacks = .{
        .create_callback = &create,
        .free_callback = &free,
    };

    fn create(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) ?*anyopaque {
        lockPool();
        defer pool_lock.unlock();

        const self = pool.create(allocator) catch return null;
        // `MemoryPool.create` hands back raw storage; the field defaults above
        // are declarations, not an initializer, so without this every binding
        // starts as whatever the pool last held. Both destruction flags were
        // reading that garbage.
        self.* = .{};
        return @ptrCast(self);
    }

    fn free(_: ?*anyopaque, _: ?*anyopaque, binding: ?*anyopaque) callconv(.c) void {
        lockPool();
        defer pool_lock.unlock();

        if (binding) |self| pool.destroy(@ptrCast(@alignCast(self)));
    }

    pub fn get(obj: *Object) ?*DestroyInstanceBinding {
        const raw_ptr = gdzig.raw.objectGetInstanceBinding(obj, @ptrCast(@constCast(&callbacks)), &callbacks);
        return @ptrCast(@alignCast(raw_ptr));
    }

    /// Panics if a dispatch into this object is still on the stack. Called from
    /// both destruction paths, so it fires whether the free came from your
    /// `destroy` or from the engine.
    ///
    /// There is no legitimate case here. `queueFree` defers, so it never trips
    /// this; what does is destroying an object from inside one of its own
    /// methods, or from a signal handler while the emitter's method is still
    /// running. Either way the dispatch returns into freed memory.
    pub fn assertNotDispatching(self: *const DestroyInstanceBinding) void {
        if (!track_dispatch) return;
        const depth = self.dispatch_depth.load(.monotonic);
        if (depth == 0) return;
        // The depth is worth printing: 1 is an ordinary free-inside-a-method,
        // while an implausible number means the binding itself is suspect.
        std.debug.panic(
            "object freed while {d} of its methods were still running; use queueFree to defer the free until the call has returned",
            .{depth},
        );
    }

    // There is deliberately no bulk teardown for `pool`.
    //
    // Godot owns each binding: it asks for one through `create_callback` and
    // gives it back through `free_callback`, on its own schedule, which for a
    // surviving object is after the extension has exited. Freeing the pool at
    // exit therefore frees storage Godot still points at -- harmless on a real
    // shutdown only because the process ends immediately after, and not
    // harmless at all on a hot reload, where the next read of a surviving
    // object's binding returns whatever now occupies that memory. It surfaced
    // as `dispatch_depth` reading 110, then 896, then 47 across three runs, and
    // the guard panicking on the garbage.
};

/// Marks an instance as being dispatched into for the lifetime of the guard.
///
/// The binding is looked up once on entry and reused on exit, so a dispatch
/// costs one `object_get_instance_binding` rather than two. That is safe
/// because the only way the binding could go away mid-dispatch is the object
/// being freed, which `assertNotDispatching` turns into a panic first.
pub const DispatchGuard = struct {
    binding: ?*DestroyInstanceBinding,

    /// Takes the instance in whatever form the dispatch site has it -- a user
    /// class pointer -- and finds the engine object behind it.
    pub fn enter(instance: anytype) DispatchGuard {
        if (!track_dispatch) return .{ .binding = null };
        // `vtable.zig` exercises the dispatch machinery in its own unit tests
        // with plain structs that are not classes and have no engine object
        // behind them. Nothing to track there.
        if (comptime !class.isClassPtr(@TypeOf(instance))) return .{ .binding = null };
        const binding = DestroyInstanceBinding.get(Object.upcast(instance));
        if (binding) |b| _ = b.dispatch_depth.fetchAdd(1, .monotonic);
        return .{ .binding = binding };
    }

    pub fn leave(self: DispatchGuard) void {
        if (!track_dispatch) return;
        if (self.binding) |b| _ = b.dispatch_depth.fetchSub(1, .monotonic);
    }
};

fn makeClassCallbacks(comptime T: type) classdb.ClassCallbacks4(T, ClassUserdataOf(T), void) {
    comptime {
        if (!@hasDecl(T, "create") and !canSynthesize(T)) @compileError(synthesisHelp(T, "create"));
        if (!@hasDecl(T, "destroy") and !canSynthesize(T)) @compileError(synthesisHelp(T, "destroy"));
    }

    const Userdata = ClassUserdataOf(T);

    const Callbacks = struct {
        /// Wraps `create` to bind the instance and send the POSTINITIALIZE notification.
        ///
        /// @since 4.4
        fn create2(userdata: Userdata, notify: bool) anyerror!*T {
            return create2Impl(userdata, notify);
        }

        /// Wraps `create` to bind the instance and send the POSTINITIALIZE notification (no userdata version).
        ///
        /// @since 4.4
        fn create2NoUserdata(notify: bool) anyerror!*T {
            return create2Impl({}, notify);
        }

        fn create2Impl(userdata: Userdata, notify: bool) anyerror!*T {
            const self = if (comptime !@hasDecl(T, "create"))
                try Synthesized(T).create(userdata)
            else if (Userdata == void)
                try T.create()
            else
                try T.create(userdata);

            const obj = Object.upcast(self);

            if (notify) {
                obj.notification(Object.NOTIFICATION_POSTINITIALIZE, .{
                    .reversed = false,
                });
            }

            return self;
        }

        /// Wraps `destroy` to set `base` to `undefined`.
        ///
        /// Godot's ownership rules of the base object are broken; they expect you
        /// to create the Base type `create()`, but not to destroy it in `destroy()`.
        ///
        /// Setting it to `undefined` will make it extremely obvious to the user that
        /// they made a mistake in Debug/ReleaseSafe builds.
        ///
        /// @since 4.1
        fn destroy(self: *T, userdata: Userdata) void {
            destroyImpl(self, userdata);
        }

        /// Wraps `destroy` (no userdata version).
        ///
        /// @since 4.1
        fn destroyNoUserdata(self: *T) void {
            destroyImpl(self, {});
        }

        /// Releases the owning handles the instance still holds.
        ///
        /// A `Gd` field is a reference someone owes back, and after this the
        /// instance is gone. Runs *before* the user's `destroy` and clears each
        /// optional, so a `destroy` that also releases finds nothing left and
        /// does nothing.
        ///
        /// Both paths reach it: the engine freeing the instance, and the user
        /// calling the class's own `destroy`, which goes out through
        /// `Object.destroy` and comes back here as the free callback. So a
        /// `Gd` field is gdzig's to release, and a `destroy` that releases one
        /// itself is doing work that is already done.
        fn releaseOwnedFields(self: *T) void {
            if (comptime @typeInfo(T) != .@"struct") return;
            // The test decides at comptime and emits nothing for the ordinary
            // field, so a class with no handles pays nothing. Calling a generic
            // helper per field instead was enough comptime work on a wide class
            // to segfault the 0.16 compiler outright.
            @setEvalBranchQuota(10_000);
            inline for (@typeInfo(T).@"struct".fields) |field| {
                if (comptime gd.isGd(field.type)) {
                    @field(self, field.name).deinit();
                } else if (comptime gd.OptionalGd(field.type) != null) {
                    if (@field(self, field.name)) |*handle| {
                        handle.deinit();
                        @field(self, field.name) = null;
                    }
                }
            }
        }

        fn destroyImpl(self: *T, userdata: Userdata) void {
            const obj = Object.upcast(self);

            // Before the guard, not after: when the user initiates destruction
            // `Object.destroy` sets `user_destroying`, and this callback then
            // returns without running the user's `destroy` again. Releasing
            // after that check would mean releasing on the engine's path only,
            // which is the rarer one.
            releaseOwnedFields(self);

            if (DestroyInstanceBinding.get(obj)) |destroy_meta| {
                destroy_meta.assertNotDispatching();
                if (destroy_meta.user_destroying) return;
                destroy_meta.engine_destroying = true;
            }
            if (comptime !@hasDecl(T, "destroy")) {
                Synthesized(T).destroy(self, userdata);
            } else if (Userdata == void) {
                T.destroy(self);
            } else {
                T.destroy(self, userdata);
            }
        }

        fn shortName(comptime qualified: []const u8) []const u8 {
            const cut = std.mem.lastIndexOfScalar(u8, qualified, '.') orelse return qualified;
            return qualified[cut + 1 ..];
        }

        /// Checks that the live object still matches the class before handing
        /// it over to the user's `recreate`.
        ///
        /// Only a hot reload gets here, and only then is the check meaningful:
        /// the class is the one the *new* library declares, while the object
        /// was made by the old one. If the declared base changed -- `Node` to
        /// `Control`, say -- then the `@ptrCast` every `recreate` performs
        /// reinterprets the old object as the new base and nothing says so.
        ///
        /// Reported rather than fatal. A panic here takes the editor down
        /// mid-reload, which is a worse answer to "you edited a base class"
        /// than an error naming what changed.
        fn assertBaseUnchanged(obj: *Object) void {
            if (comptime !@hasField(T, "base")) return;
            // `BaseOf`, not `@FieldType(...).pointer.child`: a derived user
            // class embeds its parent by value (`base: Parent`), and asking a
            // struct for its `pointer` field is a compile error rather than a
            // wrong answer. oopz already unwraps whichever shape it is.
            const Declared = class.BaseOf(T);
            const expected = StringName.fromType(Declared);
            if (obj.isClass(expected.*)) return;

            // Short names, because these are the ones Godot shows: the
            // qualified Zig name reads as `class.node.Node`.
            const shown = comptime shortName(@typeName(T));
            const base_shown = comptime shortName(@typeName(Declared));
            std.log.err(
                "{s} declares a base of {s}, but an instance being recreated is not one. " ++
                    "A class whose base changed cannot be reloaded onto its old instances; " ++
                    "restart the editor.",
                .{ shown, base_shown },
            );
        }

        fn recreate(userdata: Userdata, obj: *Object) *T {
            assertBaseUnchanged(obj);
            if (comptime !@hasDecl(T, "recreate")) return Synthesized(T).recreate(userdata, obj);
            return T.recreate(userdata, obj);
        }

        fn recreateNoUserdata(obj: *Object) *T {
            assertBaseUnchanged(obj);
            return T.recreate(obj);
        }

        fn getVirtualImpl(name: *const StringName) ?*const classdb.CallVirtual(T) {
            const UserVTable = comptime UserClassVTable(T);
            var buf: [256]u8 = undefined;
            const name_str = String.fromStringName(name.*).toLatin1Buf(buf[0..]);
            const result = UserVTable.get(name_str);
            return @ptrCast(result);
        }

        fn getVirtual2(userdata: Userdata, name: *const StringName, hash: u32) ?*const classdb.CallVirtual(T) {
            _ = hash;
            _ = userdata;
            return getVirtualImpl(name);
        }

        fn getVirtual2NoUserdata(name: *const StringName, hash: u32) ?*const classdb.CallVirtual(T) {
            _ = hash;
            return getVirtualImpl(name);
        }
    };

    return .{
        .create = if (Userdata != void) Callbacks.create2 else Callbacks.create2NoUserdata,
        .destroy = if (Userdata != void) Callbacks.destroy else Callbacks.destroyNoUserdata,
        // Gate on whether a synthesized `recreate` is actually *callable*, not
        // just on `canSynthesize`. It needs a `*Allocator`, which is only what
        // `Userdata` is when the class omits `create` or declares
        // `create(allocator: *Allocator)`. A class with the synthesizable
        // fields but its own zero-arg `create` has no allocator to hand it, and
        // the old condition still routed it to `recreateNoUserdata` -- whose
        // body calls `T.recreate` with none of the `@hasDecl` guard its
        // userdata twin has, so the class failed to build.
        //
        // Null means "not reloadable", which is the honest answer there.
        .recreate = if (@hasDecl(T, "recreate"))
            (if (Userdata != void) Callbacks.recreate else Callbacks.recreateNoUserdata)
        else if (canSynthesize(T) and Userdata == *Allocator)
            Callbacks.recreate
        else
            null,

        .get_virtual = if (Userdata != void) Callbacks.getVirtual2 else Callbacks.getVirtual2NoUserdata,
        // .get_virtual_call_data - not yet supported
        // .call_virtual_with_data - not yet supported

        .set = if (@hasDecl(T, "_set")) T._set else null,
        .get = if (@hasDecl(T, "_get")) T._get else null,
        .get_property_list = if (@hasDecl(T, "_get_property_list")) T._get_property_list else null,
        .destroy_property_list = if (@hasDecl(T, "_destroy_property_list")) T._destroy_property_list else null,
        .property_can_revert = if (@hasDecl(T, "_property_can_revert")) T._property_can_revert else null,
        .property_get_revert = if (@hasDecl(T, "_property_get_revert")) T._property_get_revert else null,
        .validate_property = if (@hasDecl(T, "_validate_property")) T._validate_property else null,
        .notification = if (@hasDecl(T, "_notification")) T._notification else null,
        .to_string = if (@hasDecl(T, "_to_string")) T._to_string else null,
        .reference = if (@hasDecl(T, "_reference")) T._reference else null,
        .unreference = if (@hasDecl(T, "_unreference")) T._unreference else null,
    };
}

const class_callback_names = [_][]const u8{
    "_destroy_property_list",
    "_get",
    "_get_property_list",
    "_get_rid",
    "_notification",
    "_property_can_revert",
    "_property_get_revert",
    "_reference",
    "_set",
    "_to_string",
    "_unreference",
    "_validate_property",
};

fn isClassCallback(comptime name: []const u8) bool {
    for (class_callback_names) |callback_name| {
        if (std.mem.eql(u8, name, callback_name)) return true;
    }
    return false;
}

fn suggestClassCallbackGodotName(comptime name: []const u8) ?[]const u8 {
    const candidate = comptime casez.comptimeConvert(common.godot_case.virtual_method, name);
    if (isClassCallback(candidate)) return candidate;
    return null;
}

/// Rejects public underscore-prefixed functions that Godot will never call.
///
/// `autoBind` deliberately leaves these functions alone because valid ones are
/// virtual overrides. Before this check, an invalid one was also left alone,
/// added to the user vtable, and then ignored forever because Godot never asks
/// for an unknown virtual name. The clean build made a spelling mistake look
/// like a game-logic bug.
fn validateVirtualMethodNames(comptime T: type, comptime EngineVTable: type) void {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") return;

    const decls = type_info.@"struct".decls;
    @setEvalBranchQuota(@max(1000, decls.len * 256));

    for (decls) |decl| {
        if (decl.name.len == 0 or decl.name[0] != '_') continue;
        if (@typeInfo(@TypeOf(@field(T, decl.name))) != .@"fn") continue;
        if (isClassCallback(decl.name)) continue;
        if (EngineVTable.internalNameForGodotName(decl.name) != null) continue;

        const prefix = "Unknown virtual method '" ++ decl.name ++ "' on '" ++ @typeName(T) ++ "'. ";
        if (suggestClassCallbackGodotName(decl.name)) |suggestion| {
            @compileError(prefix ++ "gdzig matches Godot's snake_case callback names; did you mean '" ++ suggestion ++ "'?");
        }
        if (EngineVTable.suggestGodotName(decl.name)) |suggestion| {
            @compileError(prefix ++ "gdzig matches Godot's snake_case virtual names; did you mean '" ++ suggestion ++ "'?");
        }
        @compileError(prefix ++ "Godot will never call this function. Use a virtual exposed by the base class, or make a helper non-pub and give it a non-virtual name.");
    }
}

/// Build a VTable for a user-defined class by chaining `.extend()` calls from
/// the nearest Godot (opaque) ancestor through each intermediate user struct
/// class. For example, given ClassC -> ClassB -> ClassA -> Object:
///
///   Object.VTable.extend(ClassA, ...).extend(ClassB, ...).extend(ClassC, ...)
///
/// The engine VTable already contains every valid virtual name. Empty extends
/// rebind its wrapper owner at each user-class level so an override declared on
/// any ancestor is found and receives a correctly narrowed `self` pointer.
fn UserClassVTable(comptime T: type) type {
    comptime {
        const ancestors = class.selfAndAncestorsOf(T);

        // Find the nearest opaque (Godot) ancestor — it has the root VTable.
        var godot_idx: usize = 0;
        for (ancestors, 0..) |Ancestor, i| {
            if (class.isOpaqueClass(Ancestor)) {
                godot_idx = i;
                break;
            }
        } else {
            @compileError("Type '" ++ @typeName(T) ++ "' has no Godot (opaque) class in its ancestry");
        }

        // Chain .extend() calls from the Godot class back down to T.
        // ancestors is [T, ..., GodotClass, ...] so we iterate from
        // godot_idx-1 down to 0 (inclusive).
        const EngineVTable = ancestors[godot_idx].VTable;
        var Result = EngineVTable;
        var i: usize = godot_idx;
        while (i > 0) {
            i -= 1;
            validateVirtualMethodNames(ancestors[i], EngineVTable);
            Result = Result.extend(ancestors[i], .{});
        }
        return Result;
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const MemoryPool = std.heap.MemoryPool;

const builtin = @import("builtin");

const c = @import("gdextension");
const casez = @import("casez");
const common = @import("common");
const gd = @import("../gd.zig");
const gdzig = @import("gdzig");
const class = gdzig.class;
const classdb = gdzig.class.ClassDb;
const ClassInfo4 = gdzig.class.ClassDb.ClassInfo4;
const String = gdzig.builtin.String;
const StringName = gdzig.builtin.StringName;
const Object = gdzig.class.Object;
const GeneralPurposeAllocator = gdzig.heap.GeneralPurposeAllocator;
