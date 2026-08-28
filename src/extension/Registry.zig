const Registry = @This();

allocator: Allocator,
arena: ArenaAllocator,
classes: std.ArrayList(*AnyClass),
callbacks: std.ArrayList(*AnyCallbacks),
/// Classes to hand to the editor once they exist in ClassDB. Names rather than
/// types, because by the time this is walked the type is long gone.
editor_plugins: std.ArrayList(*const StringName),

pub fn init(backing_allocator: Allocator) Registry {
    return .{
        .allocator = backing_allocator,
        .arena = .init(backing_allocator),
        .classes = .empty,
        .callbacks = .empty,
        .editor_plugins = .empty,
    };
}

pub fn deinit(self: *Registry) void {
    self.unregisterRemaining();
    self.arena.deinit();
    self.* = undefined;
}

/// Unregisters whatever the extension's own `unregister` did not.
///
/// Calling `removeClass` is the extension's job, and an extension with no
/// `unregister` at all is legal. Anything missed stays in Godot's ClassDB with
/// its callbacks in a library that is about to go, and its rpc table pointing
/// into an arena that is about to be freed. On a plain shutdown that is
/// invisible because the process ends; on a reload it is a class the engine
/// will happily instantiate into unmapped code.
///
/// Reverse order, because an inheritor has to go before its parent and a
/// subclass is registered after the class it extends.
///
/// Asking ClassDB rather than tracking a flag: the same answer covers "the
/// extension already removed it", and it cannot fall out of step with reality.
fn unregisterRemaining(self: *Registry) void {
    var i = self.classes.items.len;
    while (i > 0) {
        i -= 1;
        const any = self.classes.items[i];
        if (!classdb.classExists(any.name.*)) continue;
        any.teardown();
    }
}

/// The value type that the user passes to addClass.
/// If ClassUserdataOf(T) is a pointer, this is the child type.
/// Otherwise it's the same as ClassUserdataOf(T).
fn ClassUserdataValue(comptime T: type) type {
    const Userdata = class_mod.ClassUserdataOf(T);
    return switch (@typeInfo(Userdata)) {
        .pointer => |p| p.child,
        else => Userdata,
    };
}

/// Add a class without needing configuration.
pub fn addClass(self: *Registry, comptime T: type, userdata: ClassUserdataValue(T), options: Class(T).CreateOptions) void {
    _ = self.createClass(T, userdata, options);
}

/// Automatically register a class, bypassing the need for manual configuration.
/// Only supports classes where userdata is `Allocator` or `void`.
pub fn autoRegister(self: *Registry, comptime T: type) void {
    const UserdataVal = ClassUserdataValue(T);
    const userdata: UserdataVal = if (UserdataVal == void) {}
    else if (UserdataVal == Allocator) self.allocator
    else @compileError("autoRegister only supports Allocator or void userdata. Use createClass and autoBind for custom userdata.");
    const class = self.createClass(T, userdata, .auto);
    class.autoBind();
}

/// Create a class and return it for further configuration.
pub fn createClass(self: *Registry, comptime T: type, userdata: ClassUserdataValue(T), options: Class(T).CreateOptions) *Class(T) {
    const alloc = self.arena.allocator();
    const Userdata = class_mod.ClassUserdataOf(T);

    // Store userdata in arena and get stable pointer if needed
    const stored_userdata: Userdata = switch (@typeInfo(Userdata)) {
        .pointer => blk: {
            const stored = alloc.create(ClassUserdataValue(T)) catch @panic("OOM");
            stored.* = userdata;
            break :blk stored;
        },
        else => userdata,
    };

    const class_builder = alloc.create(Class(T)) catch @panic("OOM");
    class_builder.* = Class(T).init(self, stored_userdata, options);
    self.classes.append(alloc, class_builder.erased()) catch @panic("OOM");
    return class_builder;
}

/// Add a module. The module must have a `pub fn register(r: *Registry) void` function.
pub fn addModule(self: *Registry, comptime Module: type) void {
    Module.register(self);
}

/// Remove a module. The module must have a `pub fn unregister(r: *Registry) void` function.
pub fn removeModule(self: *Registry, comptime Module: type) void {
    Module.unregister(self);
}

/// Automatically registers a tuple of modules or classes.
/// If the type has a `register(r: *Registry)` function, it calls it (module behavior).
/// Otherwise, it assumes it's a class and calls `autoRegister` on it.
pub fn registerAll(self: *Registry, comptime items: anytype) void {
    const info = @typeInfo(@TypeOf(items));
    if (info != .@"struct" or !info.@"struct".is_tuple) {
        @compileError("registerAll expects a tuple of types");
    }
    inline for (info.@"struct".fields) |field| {
        const T = @field(items, field.name);
        if (@hasDecl(T, "register")) {
            self.addModule(T);
        } else {
            self.autoRegister(T);
        }
    }
}

/// Automatically unregisters a tuple of modules or classes.
/// Must be called with the exact same tuple used in `registerAll`, and it unregisters them in reverse order.
/// If the type has a `unregister(r: *Registry)` function, it calls it.
/// Otherwise, it assumes it's a class and calls `removeClass`.
pub fn unregisterAll(self: *Registry, comptime items: anytype) void {
    const info = @typeInfo(@TypeOf(items));
    if (info != .@"struct" or !info.@"struct".is_tuple) {
        @compileError("unregisterAll expects a tuple of types");
    }
    const fields = info.@"struct".fields;
    comptime var i = fields.len;
    inline while (i > 0) {
        i -= 1;
        const T = @field(items, fields[i].name);
        if (@hasDecl(T, "unregister")) {
            self.removeModule(T);
        } else {
            self.removeClass(T);
        }
    }
}

/// Explicitly unregister a class from Godot's ClassDB.
/// Inheritors must be unregistered before their parents.
pub fn removeClass(self: *Registry, comptime T: type) void {
    _ = self;
    teardownClass(T);
}

/// Everything undoing a registration involves, in one place so the sweep in
/// `deinit` does exactly what an explicit `removeClass` does.
fn teardownClass(comptime T: type) void {
    // The slice lives in the arena, which is about to be reset.
    rpc.Table(T).entries = &.{};
    classdb.unregisterClass(StringName.fromType(T));
}

/// Registers `T` and tells the editor to run it as a plugin.
///
/// A class descending from `EditorPlugin` is not a plugin merely by descending
/// from it: Godot has to be told, by name, once the class is in ClassDB. That
/// is `editorAddPlugin`, and reaching it by hand means a raw interface call and
/// remembering the matching remove.
///
/// Forced to the editor level regardless of what `options` says, since a plugin
/// registered at any other level is one the editor will never see.
pub fn addEditorPlugin(self: *Registry, comptime T: type, userdata: ClassUserdataValue(T), options: Class(T).CreateOptions) void {
    comptime gdzig.class.assertIsA(gdzig.class.EditorPlugin, T);

    var at_editor = options;
    at_editor.level = .editor;
    self.addClass(T, userdata, at_editor);

    const alloc = self.arena.allocator();
    self.editor_plugins.append(alloc, StringName.fromType(T)) catch @panic("OOM");
}

/// Add lifecycle callbacks.
pub fn addCallbacks(self: *Registry, comptime T: type, userdata: T, options: Callbacks(T).CreateOptions) void {
    const alloc = self.arena.allocator();

    // Store userdata in arena
    const userdata_ptr = alloc.create(T) catch @panic("OOM");
    userdata_ptr.* = userdata;

    const callbacks_obj = alloc.create(Callbacks(T)) catch @panic("OOM");
    callbacks_obj.* = Callbacks(T).init(userdata_ptr, options);
    self.callbacks.append(alloc, callbacks_obj.erased()) catch @panic("OOM");
}

pub fn enter(self: *Registry, level: InitializationLevel) void {
    // Commit registrations for this level
    for (self.classes.items) |any| {
        any.commit(any, level);
    }

    // After the commit above, because `editorAddPlugin` wants a class ClassDB
    // already knows about.
    if (level == .editor) {
        for (self.editor_plugins.items) |name| {
            gdzig.raw.editorAddPlugin(@ptrCast(name));
        }
    }

    // Call enter callbacks
    for (self.callbacks.items) |any| {
        if (any.enter_fn) |enter_fn| {
            enter_fn(any, level);
        }
    }
}

pub fn exit(self: *Registry, level: InitializationLevel) void {
    // Before the class goes, and in reverse of the order they were added.
    if (level == .editor) {
        var i = self.editor_plugins.items.len;
        while (i > 0) {
            i -= 1;
            gdzig.raw.editorRemovePlugin(@ptrCast(self.editor_plugins.items[i]));
        }
    }

    for (self.callbacks.items) |any| {
        if (any.exit_fn) |exit_fn| {
            exit_fn(any, level);
        }
    }
}

/// Type-erased class handle for heterogeneous storage.
/// Names what registration actually produced.
///
/// A class that never reaches `register` is simply absent from Godot: no error,
/// no warning, and the only symptom is a type missing from the Create Node
/// dialog. Several ways of getting that wrong are caught at build time now, but
/// a list of what *did* register turns whatever is left into something visible
/// at a glance rather than something to deduce.
///
/// Off unless asked for -- `zig build -Dlog-registration` -- since a shipping
/// game has no use for it.
pub fn logRegistered(self: *const Registry) void {
    std.log.info("gdzig: {d} class(es) registered", .{self.classes.items.len});

    var buf: [128]u8 = undefined;
    for (self.classes.items) |any| {
        var text: String = .fromStringName(any.name.*);
        defer text.deinit();
        std.log.info("gdzig:   {s}", .{text.toLatin1Buf(buf[0..])});
    }
}

const AnyClass = struct {
    commit: *const fn (*AnyClass, InitializationLevel) void,
    /// For the sweep in `deinit`: what to check, and what to do about it.
    name: *const StringName,
    teardown: *const fn () void,
};

pub fn Class(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const CreateOptions = struct {
            /// Initialization level for this class.
            level: InitializationLevel = .scene,
            /// Class cannot be instantiated directly.
            is_virtual: bool = false,
            /// Class is abstract.
            is_abstract: bool = false,
            /// Class is visible in editor and accessible from scripts.
            is_exposed: bool = true,
            /// Class is created at runtime (not saved to disk).
            is_runtime: bool = false,
            /// Custom icon path for the editor.
            icon_path: ?*const String = null,

            pub const auto: CreateOptions = .{};
        };

        any: AnyClass,
        registry: *Registry,
        userdata: class_mod.ClassUserdataOf(T),

        methods: std.ArrayList(*Method(T)),
        signals: std.ArrayList(*AnySignal),
        groups: std.ArrayList(*Group(T)),
        ungrouped_properties: std.ArrayList(*AnyProperty),
        constants: std.ArrayList(Constant),

        /// Initialization level for this class. Default is `.scene`.
        level: InitializationLevel,
        /// Class cannot be instantiated directly.
        is_virtual: bool,
        /// Class is abstract.
        is_abstract: bool,
        /// Class is visible in editor and accessible from scripts.
        is_exposed: bool,
        /// Class is created at runtime (not saved to disk).
        is_runtime: bool,
        /// Custom icon path for the editor.
        icon_path: ?*const String,

        pub fn init(registry: *Registry, userdata: class_mod.ClassUserdataOf(T), options: CreateOptions) Self {
            return .{
                .any = .{
                    .commit = @ptrCast(&commit),
                    .name = StringName.fromType(T),
                    .teardown = &tearDownSelf,
                },
                .registry = registry,
                .userdata = userdata,
                .methods = .empty,
                .signals = .empty,
                .groups = .empty,
                .ungrouped_properties = .empty,
                .constants = .empty,
                .level = options.level,
                .is_virtual = options.is_virtual,
                .is_abstract = options.is_abstract,
                .is_exposed = options.is_exposed,
                .is_runtime = options.is_runtime,
                .icon_path = options.icon_path,
            };
        }

        fn allocator(self: *Self) Allocator {
            return self.registry.arena.allocator();
        }

        pub fn erased(self: *Self) *AnyClass {
            return &self.any;
        }

        fn tearDownSelf() void {
            teardownClass(T);
        }

        /// Add a method by name. Auto-detects the Zig decl from snake_case name.
        pub fn addMethod(self: *Self, comptime name: [:0]const u8, comptime options: Method(T).CreateOptions) void {
            _ = self.createMethod(name, options);
        }

        /// Create a method by name and return it for further configuration.
        /// Auto-detects the Zig decl from snake_case name.
        pub fn createMethod(self: *Self, comptime name: [:0]const u8, comptime options: Method(T).CreateOptions) *Method(T) {
            const alloc = self.allocator();

            // Recorded where the vtable can reach it: the `_ready` wrapper is
            // chosen from `T` alone and cannot see this registry.
            if (comptime options.rpc) |config| {
                const grown = alloc.alloc(rpc.Entry, rpc.Table(T).entries.len + 1) catch @panic("OOM");
                @memcpy(grown[0..rpc.Table(T).entries.len], rpc.Table(T).entries);
                grown[grown.len - 1] = .{ .name = name, .config = config };
                rpc.Table(T).entries = grown;
            }

            const method = alloc.create(Method(T)) catch @panic("OOM");
            method.* = Method(T).fromName(name, options);
            self.methods.append(alloc, method) catch @panic("OOM");
            return method;
        }

        /// Add a property by name.
        /// Auto-detects getter/setter methods or field, unless overridden.
        pub fn addProperty(self: *Self, comptime name: [:0]const u8, options: Property(T, name).CreateOptions) void {
            _ = self.createProperty(name, options);
        }

        /// Create a property by name and return it for further configuration.
        /// Auto-detects getter/setter methods or field, unless overridden.
        pub fn createProperty(self: *Self, comptime name: [:0]const u8, options: Property(T, name).CreateOptions) *Property(T, name) {
            const alloc = self.allocator();
            const property = alloc.create(Property(T, name)) catch @panic("OOM");
            property.* = Property(T, name).init(self, options);
            self.ungrouped_properties.append(alloc, property.erased()) catch @panic("OOM");
            return property;
        }

        /// Add a signal.
        pub fn addSignal(self: *Self, comptime S: type) void {
            _ = self.createSignal(S);
        }

        /// Create a signal and return it for further configuration.
        pub fn createSignal(self: *Self, comptime S: type) *Signal(T, S) {
            const alloc = self.allocator();
            const signal = alloc.create(Signal(T, S)) catch @panic("OOM");
            signal.* = Signal(T, S).init();
            self.signals.append(alloc, signal.erased()) catch @panic("OOM");
            return signal;
        }

        /// Create a property group. Use the returned Group to add properties to it.
        pub fn createGroup(self: *Self, name: [:0]const u8, options: Group(T).CreateOptions) *Group(T) {
            const alloc = self.allocator();
            const grp = alloc.create(Group(T)) catch @panic("OOM");
            grp.* = Group(T).init(self, name, options);
            self.groups.append(alloc, grp) catch @panic("OOM");
            return grp;
        }

        /// Register an enum type. Must be `enum(i32)`.
        pub fn addEnum(self: *Self, comptime E: type) void {
            const info = @typeInfo(E);
            if (info != .@"enum") {
                @compileError("addEnum requires an enum type, got " ++ @typeName(E));
            }
            if (info.@"enum".tag_type != i32) {
                @compileError("addEnum requires enum(i32), got " ++ @typeName(E));
            }

            const alloc = self.allocator();
            const enum_name = @typeName(E);
            // Get just the type name without module path
            const short_name = blk: {
                var i = enum_name.len;
                while (i > 0) : (i -= 1) {
                    if (enum_name[i - 1] == '.') break :blk enum_name[i..];
                }
                break :blk enum_name;
            };

            inline for (info.@"enum".fields) |field| {
                self.constants.append(alloc, .{
                    .enum_name = short_name,
                    .name = field.name,
                    .value = field.value,
                    .is_bitfield = false,
                }) catch @panic("OOM");
            }
        }

        /// Register a flags type. Must be `packed struct(u32)` with bool fields.
        pub fn addFlags(self: *Self, comptime F: type) void {
            const info = @typeInfo(F);
            if (info != .@"struct" or info.@"struct".layout != .@"packed") {
                @compileError("addFlags requires a packed struct, got " ++ @typeName(F));
            }
            if (info.@"struct".backing_integer != u32) {
                @compileError("addFlags requires packed struct(u32), got " ++ @typeName(F));
            }

            const alloc = self.allocator();
            const flags_name = @typeName(F);
            // Get just the type name without module path
            const short_name = blk: {
                var i = flags_name.len;
                while (i > 0) : (i -= 1) {
                    if (flags_name[i - 1] == '.') break :blk flags_name[i..];
                }
                break :blk flags_name;
            };

            comptime var bit: u5 = 0;
            inline for (info.@"struct".fields) |field| {
                if (field.type == bool) {
                    self.constants.append(alloc, .{
                        .enum_name = short_name,
                        .name = field.name,
                        .value = @as(i64, 1) << bit,
                        .is_bitfield = true,
                    }) catch @panic("OOM");
                    bit += 1;
                }
                // Skip padding fields (non-bool integer types)
            }
        }

        /// Register a standalone integer constant.
        /// Auto-detects value from T's decl if using .auto, converting snake_case to SCREAMING_SNAKE_CASE.
        pub fn addConst(self: *Self, comptime name: [:0]const u8, comptime options: ConstCreateOptions) void {
            const decl_name = comptime casez.comptimeConvert(gdzig_case.constant, name);
            const value: i64 = if (options.value) |v| v else blk: {
                if (!@hasDecl(T, decl_name)) {
                    @compileError("No decl '" ++ decl_name ++ "' found on " ++ @typeName(T) ++ " for constant '" ++ name ++ "'");
                }
                const decl_value = @field(T, decl_name);
                break :blk switch (@typeInfo(@TypeOf(decl_value))) {
                    .int, .comptime_int => @intCast(decl_value),
                    else => @compileError("Constant '" ++ decl_name ++ "' must be an integer type"),
                };
            };

            const alloc = self.allocator();
            self.constants.append(alloc, .{
                .enum_name = "",
                .name = name,
                .value = value,
                .is_bitfield = false,
            }) catch @panic("OOM");
        }

        pub const ConstCreateOptions = struct {
            value: ?i64 = null,

            pub const auto: ConstCreateOptions = .{};
        };

        /// Whether a method name is really a property accessor -- `get_speed`
        /// for a `speed` property -- and so already bound by that property.
        fn isPropertyAccessor(comptime method_name: []const u8) bool {
            const prop = if (std.mem.startsWith(u8, method_name, "get_"))
                method_name["get_".len..]
            else if (std.mem.startsWith(u8, method_name, "set_"))
                method_name["set_".len..]
            else
                return false;
            return bindsProperty(prop);
        }

        /// Whether `autoBind` will bind a property of this name: one the
        /// `properties` tuple or a `groups` entry carries, or a field it takes
        /// on its own.
        fn bindsProperty(comptime prop: []const u8) bool {
            if (isBoundByName(prop)) return true;
            const info = @typeInfo(T);
            if (info != .@"struct") return false;
            inline for (info.@"struct".fields) |field| {
                if (!std.mem.eql(u8, field.name, prop)) continue;
                if (std.mem.eql(u8, field.name, "allocator")) return false;
                if (std.mem.eql(u8, field.name, "base")) return false;
                if (std.mem.eql(u8, field.name, "bus")) return false;
                if (std.mem.startsWith(u8, field.name, "_")) return false;
                return gdzig.builtin.Variant.Tag.forTypeOrNull(field.type) != null;
            }
            return false;
        }

        /// Whether `name` is bound by `T`'s `properties` tuple or by one of its
        /// `groups`, either of which carries the property's own options.
        fn isBoundByName(comptime name: []const u8) bool {
            return isNamedInProperties(name) or isNamedInGroups(name);
        }

        /// The property name of a `properties`/group entry, which is either a
        /// bare string or the first element of a `.{ name, options }` pair.
        fn entryName(comptime val: anytype) []const u8 {
            const info = @typeInfo(@TypeOf(val));
            return if (info == .@"struct" and info.@"struct".is_tuple) val[0] else val;
        }

        /// Whether `name` appears in one of `T`'s `groups` property lists.
        fn isNamedInGroups(comptime name: []const u8) bool {
            if (!@hasDecl(T, "groups")) return false;
            const groups = @field(T, "groups");
            const info = @typeInfo(@TypeOf(groups));
            if (info != .@"struct" or !info.@"struct".is_tuple) return false;
            inline for (info.@"struct".fields) |field| {
                const grp = @field(groups, field.name);
                const props = grp[2];
                const props_info = @typeInfo(@TypeOf(props));
                if (props_info == .@"struct" and props_info.@"struct".is_tuple) {
                    inline for (props_info.@"struct".fields) |pfield| {
                        if (std.mem.eql(u8, entryName(@field(props, pfield.name)), name)) return true;
                    }
                }
            }
            return false;
        }

        /// Whether `name` appears in `T`'s `properties` tuple, as a bare string
        /// or as the first element of a `.{ name, options }` pair.
        fn isNamedInProperties(comptime name: []const u8) bool {
            if (!@hasDecl(T, "properties")) return false;
            const properties = @field(T, "properties");
            const info = @typeInfo(@TypeOf(properties));
            if (info != .@"struct" or !info.@"struct".is_tuple) return false;
            inline for (info.@"struct".fields) |field| {
                if (std.mem.eql(u8, entryName(@field(properties, field.name)), name)) return true;
            }
            return false;
        }

        fn camelToSnake(comptime s: []const u8) [:0]const u8 {
            comptime {
                @setEvalBranchQuota(100000);
                var buf: [256]u8 = undefined;
                var len: usize = 0;
                for (s) |c| {
                    if (c >= 'A' and c <= 'Z') {
                        if (len > 0) { buf[len] = '_'; len += 1; }
                        buf[len] = c - 'A' + 'a';
                        len += 1;
                    } else {
                        buf[len] = c;
                        len += 1;
                    }
                }
                buf[len] = 0;
                var final: [len:0]u8 = undefined;
                for (buf[0..len], 0..) |char, i| final[i] = char;
                final[len] = 0;
                const final_const = final;
                return &final_const;
            }
        }

        /// Automatically registers public methods, properties, and signals for this class.
        pub fn autoBind(self: *Self) void {
            const info = @typeInfo(T);
            if (info != .@"struct") return;

            // Auto-bind signals
            if (@hasDecl(T, "signals")) {
                const signals = @field(T, "signals");
                const sig_info = @typeInfo(@TypeOf(signals));
                if (sig_info == .@"struct" and sig_info.@"struct".is_tuple) {
                    inline for (sig_info.@"struct".fields) |field| {
                        self.addSignal(@field(signals, field.name));
                    }
                }
            }

            // Auto-bind methods
            inline for (info.@"struct".decls) |decl| {
                const is_ignored = comptime std.mem.eql(u8, decl.name, "create") or
                    std.mem.eql(u8, decl.name, "recreate") or
                    std.mem.eql(u8, decl.name, "destroy") or
                    std.mem.eql(u8, decl.name, "register") or
                    std.mem.eql(u8, decl.name, "unregister") or
                    std.mem.eql(u8, decl.name, "signals") or
                    std.mem.eql(u8, decl.name, "properties") or
                    std.mem.eql(u8, decl.name, "onready") or
                    std.mem.startsWith(u8, decl.name, "_");

                if (!is_ignored) {
                    const decl_info = @typeInfo(@TypeOf(@field(T, decl.name)));
                    if (decl_info == .@"fn") {
                        const method_info = decl_info.@"fn";
                        if (method_info.params.len > 0) {
                            const first_param = method_info.params[0].type;
                            if (first_param == *T or first_param == *const T) {
                                const snake_name = comptime camelToSnake(decl.name);
                                // A `getSpeed` beside a `speed` property *is*
                                // that property's getter: `autoDetectGetter`
                                // prefers the decl over the field. Binding it
                                // here as well registers `get_speed` twice, and
                                // Godot refuses the second. Leave it to the
                                // property, which runs the same body.
                                if (comptime !isPropertyAccessor(snake_name)) {
                                    self.addMethod(snake_name, .auto);
                                }
                            }
                        }
                    }
                }
            }

            // Auto-bind properties from fields
            inline for (info.@"struct".fields) |field| {
                const is_ignored = comptime std.mem.eql(u8, field.name, "allocator") or
                    std.mem.eql(u8, field.name, "base") or
                    std.mem.eql(u8, field.name, "bus") or
                    std.mem.startsWith(u8, field.name, "_") or
                    // Listed in `properties` or in a `groups` entry below,
                    // either of which binds it with its own options. Binding it
                    // here too would register the same property twice, and
                    // Godot refuses the second with "already has property" --
                    // leaving the options ignored.
                    isBoundByName(field.name);
                
                if (!is_ignored) {
                    if (comptime gdzig.builtin.Variant.Tag.forTypeOrNull(field.type) != null) {
                        self.addProperty(field.name ++ "", .auto);
                    }
                }
            }


            // Auto-bind properties
            if (@hasDecl(T, "properties")) {
                const properties = @field(T, "properties");
                const prop_info = @typeInfo(@TypeOf(properties));
                if (prop_info == .@"struct" and prop_info.@"struct".is_tuple) {
                    inline for (prop_info.@"struct".fields) |field| {
                        const prop_val = @field(properties, field.name);
                        const val_info = @typeInfo(@TypeOf(prop_val));
                        if (val_info == .@"struct" and val_info.@"struct".is_tuple) {
                            const name_str = prop_val[0];
                            const options = comptime blk: {
                                var opts = Property(T, name_str).CreateOptions{};
                                const opts_info = @typeInfo(@TypeOf(prop_val[1])).@"struct";
                                for (opts_info.fields) |f| {
                                    @field(opts, f.name) = @field(prop_val[1], f.name);
                                }
                                break :blk opts;
                            };
                            self.addProperty(name_str, options);
                        } else {
                            self.addProperty(prop_val, .auto);
                        }
                    }
                }
            }

            // Auto-bind property groups
            if (@hasDecl(T, "groups")) {
                const groups = @field(T, "groups");
                const grp_info = @typeInfo(@TypeOf(groups));
                if (grp_info == .@"struct" and grp_info.@"struct".is_tuple) {
                    inline for (grp_info.@"struct".fields) |field| {
                        const grp_val = @field(groups, field.name);
                        const grp_name = grp_val[0];
                        const grp_options = comptime blk: {
                            var opts = Group(T).CreateOptions{};
                            const opts_info = @typeInfo(@TypeOf(grp_val[1])).@"struct";
                            for (opts_info.fields) |f| {
                                @field(opts, f.name) = @field(grp_val[1], f.name);
                            }
                            break :blk opts;
                        };
                        const group = self.createGroup(grp_name, grp_options);
                        
                        const grp_props = grp_val[2];
                        const props_info = @typeInfo(@TypeOf(grp_props));
                        if (props_info == .@"struct" and props_info.@"struct".is_tuple) {
                            inline for (props_info.@"struct".fields) |pfield| {
                                const prop_val = @field(grp_props, pfield.name);
                                const val_info = @typeInfo(@TypeOf(prop_val));
                                if (val_info == .@"struct" and val_info.@"struct".is_tuple) {
                                    const name_str = prop_val[0];
                                    const options = comptime blk: {
                                        var opts = Property(T, name_str).CreateOptions{};
                                        const o_info = @typeInfo(@TypeOf(prop_val[1])).@"struct";
                                        for (o_info.fields) |f| {
                                            @field(opts, f.name) = @field(prop_val[1], f.name);
                                        }
                                        break :blk opts;
                                    };
                                    group.addProperty(name_str, options);
                                } else {
                                    group.addProperty(prop_val, .auto);
                                }
                            }
                        }
                    }
                }
            }
        }

        //
        // Registration
        //

        fn commit(any: *AnyClass, level: InitializationLevel) void {
            const self: *Self = @fieldParentPtr("any", any);
            if (self.level != level) return;

            // 1. Register the class itself
            self.registerClass();

            // 2. Resolve properties first (may create new methods for auto-detected getters/setters)
            for (self.ungrouped_properties.items) |property| {
                property.resolve(property, @ptrCast(&self.methods));
            }
            for (self.groups.items) |grp| {
                grp.resolveEntries();
            }

            // 3. Register all methods (including auto-generated ones from properties)
            for (self.methods.items) |method| {
                method.register();
            }

            // 4. Register all signals
            for (self.signals.items) |signal| {
                signal.register(signal);
            }

            // 5. Register ungrouped properties
            for (self.ungrouped_properties.items) |property| {
                property.register(property);
            }

            // 6. Register groups with their properties and subgroups
            for (self.groups.items) |grp| {
                grp.register();
                grp.registerEntries();
            }

            // 7. Register constants (enums, flags, standalone constants)
            const class_name = StringName.fromType(T);
            for (self.constants.items) |constant| {
                var enum_name: StringName = .fromLatin1(constant.enum_name, true);
                var const_name: StringName = .fromLatin1(constant.name, true);
                classdb.registerIntegerConstant(class_name, &enum_name, &const_name, constant.value, constant.is_bitfield);
            }
        }

        const Constant = struct {
            enum_name: [:0]const u8,
            name: [:0]const u8,
            value: i64,
            is_bitfield: bool,
        };

        fn registerClass(self: *Self) void {
            const Userdata = class_mod.ClassUserdataOf(T);
            class_mod.registerClass(T, if (Userdata != void) .{
                .userdata = self.userdata,
                .is_virtual = self.is_virtual,
                .is_abstract = self.is_abstract,
                .is_exposed = self.is_exposed,
                .is_runtime = self.is_runtime,
                .icon_path = self.icon_path,
            } else .{
                .is_virtual = self.is_virtual,
                .is_abstract = self.is_abstract,
                .is_exposed = self.is_exposed,
                .is_runtime = self.is_runtime,
                .icon_path = self.icon_path,
            });
        }
    };
}

/// Method registration info, generic over class type.
pub fn Method(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const CreateOptions = struct {
            /// Method flags.
            flags: MethodFlags = .{},
            /// Default argument values.
            default_arguments: []const *const Variant = &.{},
            /// Makes the method callable over the network, the equivalent of
            /// GDScript's `@rpc(...)` on the function. Applied per instance in
            /// `_ready`, since `Node.rpcConfig` configures a node rather than a
            /// class. See `src/rpc.zig`.
            rpc: ?rpc.Config = null,

            pub const auto: CreateOptions = .{};
        };

        name: [:0]const u8,
        // These are needed for Property to infer property type
        return_info: ?classdb.PropertyInfo,
        arg_info: []const classdb.PropertyInfo,
        // Registration function captures the method config at comptime
        register_fn: *const fn () void,

        /// Create a method from a name string.
        /// Looks up the corresponding camelCase decl on T (e.g., "on_timeout" -> T.onTimeout).
        pub fn fromName(comptime name: [:0]const u8, comptime options: CreateOptions) Self {
            // Convert snake_case to camelCase and verify decl exists
            const decl_name = comptime casez.comptimeConvert(gdzig_case.method, name);
            if (!@hasDecl(T, decl_name)) {
                @compileError("No decl '" ++ decl_name ++ "' found on " ++ @typeName(T) ++ " for method '" ++ name ++ "'");
            }
            return fromDecl(name, decl_name, options);
        }

        /// Create a method from an explicit decl name.
        /// name: the method name Godot sees (e.g., "get_health")
        /// decl_name: the Zig decl name (e.g., "getHealth")
        pub fn fromDecl(comptime name: [:0]const u8, comptime decl_name: [:0]const u8, comptime options: CreateOptions) Self {
            const config = method_mod.MethodConfig(T).fromName(name, decl_name, options);
            return .{
                .name = name,
                .return_info = if (config.return_value_info) |info| info.* else null,
                .arg_info = config.argument_info,
                .register_fn = &struct {
                    fn doRegister() void {
                        method_mod.registerMethod(T, config);
                    }
                }.doRegister,
            };
        }

        /// Create a getter method for a field.
        pub fn fieldGetter(comptime name: [:0]const u8, comptime field_name: [:0]const u8) Self {
            const config = method_mod.MethodConfig(T).getter(name, field_name);
            return .{
                .name = name,
                .return_info = if (config.return_value_info) |info| info.* else null,
                .arg_info = config.argument_info,
                .register_fn = &struct {
                    fn doRegister() void {
                        method_mod.registerMethod(T, config);
                    }
                }.doRegister,
            };
        }

        /// Create a setter method for a field.
        pub fn fieldSetter(comptime name: [:0]const u8, comptime field_name: [:0]const u8) Self {
            const config = method_mod.MethodConfig(T).setter(name, field_name);
            return .{
                .name = name,
                .return_info = if (config.return_value_info) |info| info.* else null,
                .arg_info = config.argument_info,
                .register_fn = &struct {
                    fn doRegister() void {
                        method_mod.registerMethod(T, config);
                    }
                }.doRegister,
            };
        }

        pub fn register(self: *const Self) void {
            self.register_fn();
        }
    };
}

/// Property accessor: auto-detect, none, or explicit method.
pub fn Accessor(comptime T: type) type {
    return union(enum) {
        auto,
        none,
        method: *const Method(T),
    };
}

/// Type-erased property for heterogeneous storage.
const AnyProperty = struct {
    resolve: *const fn (*AnyProperty, *anyopaque) void,
    register: *const fn (*AnyProperty) void,
};

/// Property registration info, generic over class type and property name.
pub fn Property(comptime T: type, comptime name: [:0]const u8) type {
    return struct {
        const Self = @This();

        pub const CreateOptions = struct {
            /// Override the getter (.auto = auto-detect, .none = no getter, .method = use this).
            getter: Accessor(T) = .auto,
            /// Override the setter (.auto = auto-detect, .none = no setter, .method = use this).
            setter: Accessor(T) = .auto,
            /// Property hint.
            hint: PropertyHint = .property_hint_none,
            /// Hint string, in whatever format `hint` expects.
            ///
            /// A plain slice rather than a `String`: these are literals, and a
            /// `String` here would have to be built by the caller and outlive
            /// the call, with nothing to release it. `register` builds one and
            /// frees it, since the engine copies what it is given.
            hint_string: [:0]const u8 = "",
            /// Usage flags.
            usage: PropertyUsageFlags = .property_usage_default,
            /// Index for indexed properties.
            index: ?i64 = null,

            pub const auto: CreateOptions = .{};

            // The `@export_*` family. Each is the hint plus the hint-string
            // format Godot expects, so the annotation you know from GDScript
            // maps to a constructor of the same name rather than to a pair of
            // fields you have to get right by hand.

            /// `@export_range`. `extra` takes Godot's modifiers verbatim, e.g.
            /// `"or_greater"`, `"exp"`, `"suffix:m"`, comma-separated.
            pub fn range(comptime min: comptime_float, comptime max: comptime_float, comptime step: comptime_float, comptime extra: [:0]const u8) CreateOptions {
                const base = std.fmt.comptimePrint("{d},{d},{d}", .{ min, max, step });
                return .{ .hint = .property_hint_range, .hint_string = if (extra.len == 0) base else base ++ "," ++ extra };
            }

            /// `@export_enum`. Names, or `"Name:value"` pairs.
            pub fn enumOf(comptime entries: []const [:0]const u8) CreateOptions {
                return .{ .hint = .property_hint_enum, .hint_string = comptime join(entries) };
            }

            /// `@export_flags`. Entries are `"Name:bit"`.
            pub fn flags(comptime entries: []const [:0]const u8) CreateOptions {
                return .{ .hint = .property_hint_flags, .hint_string = comptime join(entries) };
            }

            /// `@export_file`. `filter` is e.g. `"*.png"`, or empty for any.
            pub fn file(comptime filter: [:0]const u8) CreateOptions {
                return .{ .hint = .property_hint_file, .hint_string = filter };
            }

            /// `@export_global_file`.
            pub fn globalFile(comptime filter: [:0]const u8) CreateOptions {
                return .{ .hint = .property_hint_global_file, .hint_string = filter };
            }

            /// `@export_dir`.
            pub fn dir() CreateOptions {
                return .{ .hint = .property_hint_dir };
            }

            /// `@export_global_dir`.
            pub fn globalDir() CreateOptions {
                return .{ .hint = .property_hint_global_dir };
            }

            /// `@export_multiline`.
            pub fn multiline() CreateOptions {
                return .{ .hint = .property_hint_multiline_text };
            }

            /// `@export_placeholder`.
            pub fn placeholder(comptime text: [:0]const u8) CreateOptions {
                return .{ .hint = .property_hint_placeholder_text, .hint_string = text };
            }

            /// `@export_color_no_alpha`.
            pub fn colorNoAlpha() CreateOptions {
                return .{ .hint = .property_hint_color_no_alpha };
            }

            /// `@export_node_path`. Restricts the picker to these node types.
            pub fn nodePath(comptime types: []const [:0]const u8) CreateOptions {
                return .{ .hint = .property_hint_node_path_valid_types, .hint_string = comptime join(types) };
            }

            /// `@export_exp_easing`. `mode` is `""`, `"attenuation"`, or
            /// `"positive_only"`.
            pub fn expEasing(comptime mode: [:0]const u8) CreateOptions {
                return .{ .hint = .property_hint_exp_easing, .hint_string = mode };
            }

            /// `@export_tool_button`. `hint_string` is `"Label"` or
            /// `"Label,IconName"`.
            pub fn toolButton(comptime label: [:0]const u8) CreateOptions {
                return .{ .hint = .property_hint_tool_button, .hint_string = label };
            }

            /// `@export_storage`: saved with the scene, hidden from the
            /// inspector. A usage change rather than a hint.
            pub fn storage() CreateOptions {
                return .{ .usage = .property_usage_no_editor };
            }

            /// `@export_flags_2d_physics` and its six siblings. `which` names
            /// the layer set, so one constructor covers all of them.
            pub fn layers(comptime which: Layers) CreateOptions {
                return .{ .hint = switch (which) {
                    .physics_2d => .property_hint_layers_2d_physics,
                    .render_2d => .property_hint_layers_2d_render,
                    .navigation_2d => .property_hint_layers_2d_navigation,
                    .physics_3d => .property_hint_layers_3d_physics,
                    .render_3d => .property_hint_layers_3d_render,
                    .navigation_3d => .property_hint_layers_3d_navigation,
                    .avoidance => .property_hint_layers_avoidance,
                } };
            }

            pub const Layers = enum {
                physics_2d,
                render_2d,
                navigation_2d,
                physics_3d,
                render_3d,
                navigation_3d,
                avoidance,
            };

            fn join(comptime entries: []const [:0]const u8) [:0]const u8 {
                comptime {
                    var out: [:0]const u8 = "";
                    for (entries, 0..) |entry, i| {
                        out = if (i == 0) entry else out ++ "," ++ entry;
                    }
                    return out;
                }
            }
        };

        any: AnyProperty,
        class: *Class(T),
        options: CreateOptions,

        // Resolved at commit time
        resolved_getter: ?*const Method(T) = null,
        resolved_setter: ?*const Method(T) = null,

        pub fn init(class: *Class(T), options: CreateOptions) Self {
            return .{
                .any = .{
                    .resolve = @ptrCast(&doResolve),
                    .register = @ptrCast(&doRegister),
                },
                .class = class,
                .options = options,
            };
        }

        pub fn erased(self: *Self) *AnyProperty {
            return &self.any;
        }

        /// Resolve getter/setter methods (may create new methods for auto-detection).
        fn doResolve(any: *AnyProperty, methods_opaque: *anyopaque) void {
            const self: *Self = @alignCast(@fieldParentPtr("any", any));
            const methods: *std.ArrayList(*Method(T)) = @ptrCast(@alignCast(methods_opaque));
            const alloc = self.class.allocator();

            // Indexed properties cannot use auto-detection
            if (self.options.index != null) {
                if (self.options.getter == .auto or self.options.setter == .auto) {
                    @panic("Indexed properties cannot use .auto for getter/setter. Use explicit .{ .method = ... } instead.");
                }
            }

            // Resolve getter/setter and store for later registration
            self.resolved_getter = resolveGetter(self.options.getter, alloc, methods);
            self.resolved_setter = resolveSetter(self.options.setter, alloc, methods);
        }

        /// Register the property with Godot (after methods have been registered).
        fn doRegister(any: *AnyProperty) void {
            const self: *Self = @alignCast(@fieldParentPtr("any", any));

            // Determine property type from getter or setter
            const prop_type: Variant.Tag = if (self.resolved_getter) |g|
                g.return_info.?.type
            else if (self.resolved_setter) |s|
                s.arg_info[0].type
            else
                .nil;

            // Register the property
            const class_name = StringName.fromType(T);
            var property_name: StringName = .fromLatin1(name, true);

            var getter_name: StringName = if (self.resolved_getter) |g| .fromLatin1(g.name, true) else .empty;
            var setter_name: StringName = if (self.resolved_setter) |s| .fromLatin1(s.name, true) else .empty;

            // Built here and released after registering: the engine copies
            // what it is handed, so nothing needs to keep this alive.
            var hint_string: String = .fromLatin1(self.options.hint_string);
            defer hint_string.deinit();

            // A `Variant` property is typed NIL, which Godot otherwise reads
            // as "no type at all" -- it then fails to find a conversion
            // function and rejects the property with "Getting Variant
            // conversion function with invalid type". The flag is what says
            // NIL means "any type" here.
            //
            // Guarded on an accessor existing, because `prop_type` is also NIL
            // when neither a getter nor a setter resolved, and that property is
            // broken for a different reason.
            var usage = self.options.usage;
            if (prop_type == .nil and (self.resolved_getter != null or self.resolved_setter != null)) {
                usage.property_usage_nil_is_variant = true;
            }

            const info: classdb.PropertyInfo = .{
                .type = prop_type,
                .name = &property_name,
                .hint = self.options.hint,
                .hint_string = &hint_string,
                .usage = usage,
            };

            if (self.options.index) |idx| {
                classdb.registerPropertyIndexed(class_name, &info, &setter_name, &getter_name, idx);
            } else {
                classdb.registerProperty(class_name, &info, &setter_name, &getter_name);
            }
        }

        // Comptime constants for auto-detection
        const camel = casez.comptimeConvert(gdzig_case.method, name);
        const upper_first = [1]u8{std.ascii.toUpper(camel[0])};
        const getter_decl = "get" ++ upper_first ++ camel[1..];
        const setter_decl = "set" ++ upper_first ++ camel[1..];
        const getter_method_name = "get_" ++ name;
        const setter_method_name = "set_" ++ name;

        // Whether auto-detection can find a getter/setter
        const can_auto_getter = @hasDecl(T, getter_decl) or @hasField(T, camel) or @hasField(T, name);
        const can_auto_setter = @hasDecl(T, setter_decl) or @hasField(T, camel) or @hasField(T, name);

        fn resolveGetter(
            getter: Accessor(T),
            alloc: Allocator,
            methods: *std.ArrayList(*Method(T)),
        ) ?*const Method(T) {
            return switch (getter) {
                // Not `@compileError`: `getter` is a runtime value, so every
                // arm of this switch is analysed even when the caller passed
                // `.method`, and a compile error here fires for properties that
                // are perfectly well formed. It stays a runtime failure, but
                // one that says which property and what was looked for --
                // `unreachable` said neither.
                .auto => if (can_auto_getter) autoDetectGetter(alloc, methods) else @panic(
                    "property '" ++ name ++ "' on " ++ @typeName(T) ++ " has no readable source. " ++
                        "Looked for a field '" ++ name ++ "' or '" ++ camel ++ "', or a method '" ++ getter_decl ++ "'. " ++
                        "Name one with .getter = .{ .method = ... }, or use .getter = .none for a write-only property.",
                ),
                .none => null,
                .method => |m| m,
            };
        }

        fn resolveSetter(
            setter: Accessor(T),
            alloc: Allocator,
            methods: *std.ArrayList(*Method(T)),
        ) ?*const Method(T) {
            return switch (setter) {
                .auto => if (can_auto_setter) autoDetectSetter(alloc, methods) else @panic(
                    "property '" ++ name ++ "' on " ++ @typeName(T) ++ " has no writable target. " ++
                        "Looked for a field '" ++ name ++ "' or '" ++ camel ++ "', or a method '" ++ setter_decl ++ "'. " ++
                        "Name one with .setter = .{ .method = ... }, or use .setter = .none for a read-only property.",
                ),
                .none => null,
                .method => |m| m,
            };
        }

        fn autoDetectGetter(
            alloc: Allocator,
            methods: *std.ArrayList(*Method(T)),
        ) *const Method(T) {
            // Auto-detect: check for getX method, then field
            if (@hasDecl(T, getter_decl)) {
                const m = alloc.create(Method(T)) catch @panic("OOM");
                m.* = Method(T).fromDecl(getter_method_name, getter_decl, .{});
                methods.append(alloc, m) catch @panic("OOM");
                return m;
            } else if (@hasField(T, camel)) {
                const m = alloc.create(Method(T)) catch @panic("OOM");
                m.* = Method(T).fieldGetter(getter_method_name, camel);
                methods.append(alloc, m) catch @panic("OOM");
                return m;
            } else {
                const m = alloc.create(Method(T)) catch @panic("OOM");
                m.* = Method(T).fieldGetter(getter_method_name, name);
                methods.append(alloc, m) catch @panic("OOM");
                return m;
            }
        }

        fn autoDetectSetter(
            alloc: Allocator,
            methods: *std.ArrayList(*Method(T)),
        ) *const Method(T) {
            // Auto-detect: check for setX method, then field
            if (@hasDecl(T, setter_decl)) {
                const m = alloc.create(Method(T)) catch @panic("OOM");
                m.* = Method(T).fromDecl(setter_method_name, setter_decl, .{});
                methods.append(alloc, m) catch @panic("OOM");
                return m;
            } else if (@hasField(T, camel)) {
                const m = alloc.create(Method(T)) catch @panic("OOM");
                m.* = Method(T).fieldSetter(setter_method_name, camel);
                methods.append(alloc, m) catch @panic("OOM");
                return m;
            } else {
                const m = alloc.create(Method(T)) catch @panic("OOM");
                m.* = Method(T).fieldSetter(setter_method_name, name);
                methods.append(alloc, m) catch @panic("OOM");
                return m;
            }
        }
    };
}

/// Type-erased signal for heterogeneous storage.
const AnySignal = struct {
    register: *const fn (*AnySignal) void,
};

pub fn Signal(comptime T: type, comptime S: type) type {
    return struct {
        const Self = @This();

        any: AnySignal,

        pub fn init() Self {
            return .{
                .any = .{
                    .register = @ptrCast(&doRegister),
                },
            };
        }

        pub fn erased(self: *Self) *AnySignal {
            return &self.any;
        }

        fn doRegister(_: *AnySignal) void {
            const class_name = StringName.fromType(T);
            const signal_name = StringName.fromSignal(S);

            const fields = @typeInfo(S).@"struct".fields;
            var arg_info: [fields.len]classdb.PropertyInfo = undefined;
            var names: [fields.len]*const StringName = undefined;
            inline for (fields, 0..) |field, i| {
                names[i] = StringName.fromComptimeLatin1(field.name);
                arg_info[i] = .{
                    .type = Variant.Tag.forType(field.type),
                    .name = names[i],
                };
            }

            classdb.registerSignal(class_name, signal_name, &arg_info);
        }
    };
}

/// Property group, generic over class type.
/// Groups own their properties and subgroups, handling registration order.
pub fn Group(comptime T: type) type {
    return struct {
        const Self = @This();

        const Entry = union(enum) {
            property: *AnyProperty,
            subgroup: *Subgroup(T),
        };

        /// Options for a property group.
        pub const CreateOptions = struct {
            /// Shared prefix stripped from member names in the inspector, the
            /// second argument to GDScript's `@export_group`. A group "Stats"
            /// with prefix "stat_" shows `stat_health` as just "Health".
            prefix: [:0]const u8 = "",
        };

        class: *Class(T),
        name: [:0]const u8,
        prefix: [:0]const u8,
        entries: std.ArrayList(Entry),

        pub fn init(class: *Class(T), name: [:0]const u8, options: CreateOptions) Self {
            return .{
                .class = class,
                .name = name,
                .prefix = options.prefix,
                .entries = .empty,
            };
        }

        /// Add a property by name to this group.
        pub fn addProperty(self: *Self, comptime prop_name: [:0]const u8, options: Property(T, prop_name).CreateOptions) void {
            _ = self.createProperty(prop_name, options);
        }

        /// Create a property by name and return it for further configuration.
        pub fn createProperty(self: *Self, comptime prop_name: [:0]const u8, options: Property(T, prop_name).CreateOptions) *Property(T, prop_name) {
            const alloc = self.class.allocator();
            const property = alloc.create(Property(T, prop_name)) catch @panic("OOM");
            property.* = Property(T, prop_name).init(self.class, options);
            self.entries.append(alloc, .{ .property = property.erased() }) catch @panic("OOM");
            return property;
        }

        /// Add a subgroup within this group.
        pub fn createSubgroup(self: *Self, subgroup_name: [:0]const u8, options: Subgroup(T).CreateOptions) *Subgroup(T) {
            const alloc = self.class.allocator();
            const subgrp = alloc.create(Subgroup(T)) catch @panic("OOM");
            subgrp.* = Subgroup(T).init(self.class, subgroup_name, options);
            self.entries.append(alloc, .{ .subgroup = subgrp }) catch @panic("OOM");
            return subgrp;
        }

        pub fn register(self: *const Self) void {
            const class_name = StringName.fromType(T);
            // Both are freed after registering; the engine copies them.
            var group_string: String = .fromLatin1(self.name);
            defer group_string.deinit();
            var prefix: String = .fromLatin1(self.prefix);
            defer prefix.deinit();

            classdb.registerPropertyGroup(class_name, &group_string, &prefix);
        }

        /// Resolve all properties in this group (creates auto-detected methods).
        pub fn resolveEntries(self: *Self) void {
            for (self.entries.items) |entry| {
                switch (entry) {
                    .property => |property| property.resolve(property, @ptrCast(&self.class.methods)),
                    .subgroup => |subgroup| subgroup.resolveProperties(),
                }
            }
        }

        /// Register all properties in this group (after methods have been registered).
        pub fn registerEntries(self: *Self) void {
            for (self.entries.items) |entry| {
                switch (entry) {
                    .property => |property| property.register(property),
                    .subgroup => |subgroup| {
                        subgroup.register();
                        subgroup.registerProperties();
                    },
                }
            }
        }
    };
}

/// Property subgroup, generic over class type.
/// Subgroups can only contain properties (no nesting).
pub fn Subgroup(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Options for a property subgroup. See `Group(T).CreateOptions`.
        pub const CreateOptions = struct {
            prefix: [:0]const u8 = "",
        };

        class: *Class(T),
        name: [:0]const u8,
        prefix: [:0]const u8,
        properties: std.ArrayList(*AnyProperty),

        pub fn init(class: *Class(T), subgroup_name: [:0]const u8, options: CreateOptions) Self {
            return .{
                .class = class,
                .name = subgroup_name,
                .prefix = options.prefix,
                .properties = .empty,
            };
        }

        /// Add a property by name to this subgroup.
        pub fn addProperty(self: *Self, comptime prop_name: [:0]const u8, options: Property(T, prop_name).CreateOptions) void {
            _ = self.createProperty(prop_name, options);
        }

        /// Create a property by name and return it for further configuration.
        pub fn createProperty(self: *Self, comptime prop_name: [:0]const u8, options: Property(T, prop_name).CreateOptions) *Property(T, prop_name) {
            const alloc = self.class.allocator();
            const property = alloc.create(Property(T, prop_name)) catch @panic("OOM");
            property.* = Property(T, prop_name).init(self.class, options);
            self.properties.append(alloc, property.erased()) catch @panic("OOM");
            return property;
        }

        pub fn register(self: *const Self) void {
            const class_name = StringName.fromType(T);
            var subgroup_string: String = .fromLatin1(self.name);
            defer subgroup_string.deinit();
            var prefix: String = .fromLatin1(self.prefix);
            defer prefix.deinit();

            classdb.registerPropertySubgroup(class_name, &subgroup_string, &prefix);
        }

        /// Resolve all properties in this subgroup (creates auto-detected methods).
        pub fn resolveProperties(self: *Self) void {
            for (self.properties.items) |property| {
                property.resolve(property, @ptrCast(&self.class.methods));
            }
        }

        /// Register all properties in this subgroup (after methods have been registered).
        pub fn registerProperties(self: *Self) void {
            for (self.properties.items) |property| {
                property.register(property);
            }
        }
    };
}

/// Type-erased callbacks for heterogeneous storage.
const AnyCallbacks = struct {
    enter_fn: ?*const fn (*AnyCallbacks, InitializationLevel) void,
    exit_fn: ?*const fn (*AnyCallbacks, InitializationLevel) void,
};

fn Callbacks(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const CreateOptions = struct {
            enter: ?*const fn (*T, InitializationLevel) void = if (@hasDecl(T, "enter")) T.enter else null,
            exit: ?*const fn (*T, InitializationLevel) void = if (@hasDecl(T, "exit")) T.exit else null,

            pub const auto: CreateOptions = .{};
        };

        any: AnyCallbacks,
        userdata: *T,
        enter: ?*const fn (*T, InitializationLevel) void,
        exit: ?*const fn (*T, InitializationLevel) void,

        pub fn init(userdata: *T, options: CreateOptions) Self {
            return .{
                .any = .{
                    .enter_fn = if (options.enter != null) @ptrCast(&doEnter) else null,
                    .exit_fn = if (options.exit != null) @ptrCast(&doExit) else null,
                },
                .userdata = userdata,
                .enter = options.enter,
                .exit = options.exit,
            };
        }

        pub fn erased(self: *Self) *AnyCallbacks {
            return &self.any;
        }

        fn doEnter(any: *AnyCallbacks, level: InitializationLevel) void {
            const self: *Self = @fieldParentPtr("any", any);
            self.enter.?(self.userdata, level);
        }

        fn doExit(any: *AnyCallbacks, level: InitializationLevel) void {
            const self: *Self = @fieldParentPtr("any", any);
            self.exit.?(self.userdata, level);
        }
    };
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const casez = @import("casez");
const common = @import("common");
const gdzig_case = common.gdzig_case;
const godot_case = common.godot_case;

const gdzig = @import("gdzig");
const classdb = gdzig.class.ClassDb;
const rpc = @import("../rpc.zig");
const MethodFlags = gdzig.global.MethodFlags;
const PropertyHint = gdzig.global.PropertyHint;
const PropertyUsageFlags = gdzig.global.PropertyUsageFlags;
const String = gdzig.builtin.String;
const StringName = gdzig.builtin.StringName;
const Variant = gdzig.builtin.Variant;

const class_mod = @import("class.zig");
const method_mod = @import("method.zig");
const InitializationLevel = @import("../extension.zig").InitializationLevel;
