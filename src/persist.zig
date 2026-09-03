const std = @import("std");
const gdzig = @import("gdzig.zig");
const Object = gdzig.class.Object;
const Variant = gdzig.builtin.Variant;
const StringName = gdzig.builtin.StringName;

const key_prefix = "gdzig_persist_";

/// A transactional view of persisted hot-reload metadata.
///
/// Migration hooks read the old state through `get`/`getVariant` and stage
/// changes with `set`, `setVariant`, `remove`, or `rename`. gdzig applies the
/// staged changes only after every migration step succeeds and the resulting
/// state can be decoded by the current struct.
pub const Migration = struct {
    const Change = struct {
        key: StringName,
        value: ?Variant,

        fn deinit(self: *Change) void {
            self.key.deinit();
            if (self.value) |*value| value.deinit();
        }
    };

    base: *Object,
    changes: std.ArrayList(Change) = .empty,

    fn init(base: anytype) Migration {
        return .{ .base = gdzig.class.upcast(*Object, base) };
    }

    fn deinit(self: *Migration) void {
        for (self.changes.items) |*change| change.deinit();
        self.changes.deinit(gdzig.engine_allocator);
    }

    /// Return an owned copy of a persisted value, including staged changes.
    /// The caller must call `deinit` on the returned Variant.
    pub fn getVariant(self: *const Migration, comptime name: [:0]const u8) ?Variant {
        var key = fieldKey(name);
        defer key.deinit();

        if (self.findChange(key)) |change| {
            return if (change.value) |value| value.clone() else null;
        }

        if (!self.base.hasMeta(key)) return null;
        return self.base.getMeta(key, .{});
    }

    /// Decode a persisted value, including staged changes.
    /// Owning return types transfer ownership to the caller.
    pub fn get(self: *const Migration, comptime T: type, comptime name: [:0]const u8) ?T {
        if (comptime Variant.Tag.forTypeOrNull(T) == null) {
            @compileError("persist.Migration.get does not support " ++ @typeName(T));
        }

        var value = self.getVariant(name) orelse return null;
        defer value.deinit();
        return value.as(T);
    }

    /// Stage a persisted value. The migration owns its own copy.
    pub fn setVariant(self: *Migration, comptime name: [:0]const u8, value: Variant) !void {
        try self.stage(name, value);
    }

    /// Encode and stage a supported value.
    pub fn set(self: *Migration, comptime name: [:0]const u8, value: anytype) !void {
        const T = @TypeOf(value);
        if (comptime Variant.Tag.forTypeOrNull(T) == null) {
            @compileError("persist.Migration.set does not support " ++ @typeName(T));
        }

        const encoded = Variant.init(T, value);
        defer encoded.deinit();
        try self.stage(name, encoded);
    }

    /// Stage removal of a persisted value.
    pub fn remove(self: *Migration, comptime name: [:0]const u8) !void {
        try self.stage(name, null);
    }

    /// Rename a persisted key without decoding its value.
    /// Returns false when the old key does not exist.
    pub fn rename(self: *Migration, comptime old_name: [:0]const u8, comptime new_name: [:0]const u8) !bool {
        var value = self.getVariant(old_name) orelse return false;
        defer value.deinit();

        try self.setVariant(new_name, value);
        try self.remove(old_name);
        return true;
    }

    fn findChange(self: *const Migration, key: StringName) ?*const Change {
        var index = self.changes.items.len;
        while (index > 0) {
            index -= 1;
            const change = &self.changes.items[index];
            if (change.key.eql(key)) return change;
        }
        return null;
    }

    fn findChangeMut(self: *Migration, key: StringName) ?*Change {
        var index = self.changes.items.len;
        while (index > 0) {
            index -= 1;
            const change = &self.changes.items[index];
            if (change.key.eql(key)) return change;
        }
        return null;
    }

    fn stage(self: *Migration, comptime name: [:0]const u8, value: ?Variant) !void {
        var key = fieldKey(name);
        if (self.findChangeMut(key)) |change| {
            key.deinit();
            if (change.value) |*previous| previous.deinit();
            change.value = if (value) |new_value| new_value.clone() else null;
            return;
        }

        errdefer key.deinit();
        var stored: ?Variant = if (value) |new_value| new_value.clone() else null;
        errdefer if (stored) |*new_value| new_value.deinit();
        try self.changes.append(gdzig.engine_allocator, .{ .key = key, .value = stored });
    }

    fn commit(self: *const Migration) void {
        for (self.changes.items) |change| {
            if (change.value) |value| {
                self.base.setMeta(change.key, value);
            } else {
                self.base.removeMeta(change.key);
            }
        }
    }
};

/// Automatically persist all supported Zig struct fields to Godot object metadata.
/// Call this during `destroy()` or `_exit_tree()`.
///
/// A class may opt into versioned migrations by declaring both a positive
/// `persist_version` integer and
/// `migratePersisted(from_version: u32, state: *persist.Migration) !void`.
pub fn autoPersist(self: anytype) void {
    const T = validatePersistType(@TypeOf(self.*), "autoPersist");
    const current_version = comptime schemaVersion(T);

    // A remaining payload means an earlier restore could not consume it. Do
    // not let this instance's defaults overwrite the recovery copy when it is
    // destroyed during the next reload attempt.
    if (hasPersistedPayload(self.base)) {
        std.log.warn(
            "gdzig: refusing to overwrite unconsumed persisted state for {s}",
            .{@typeName(T)},
        );
        return;
    }

    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime !isPersistedField(field)) continue;

        if (comptime Variant.Tag.forTypeOrNull(field.type) != null) {
            const key = StringName.fromComptimeLatin1(key_prefix ++ field.name);
            const val = Variant.init(field.type, @field(self, field.name));
            self.base.setMeta(key.*, val);
            val.deinit();
        }
    }

    if (comptime current_version > 0) writeVersion(self.base, current_version);
}

/// Automatically restore all supported Zig struct fields from Godot object metadata.
/// Call this during `create()` or `_enter_tree()`.
///
/// A restored owning value replaces and releases the field's current value.
/// Metadata is consumed only after it decodes successfully; incompatible data
/// is left in place so a failed hot reload does not destroy the last good copy.
/// Versioned migrations are applied one version at a time and committed only
/// when the complete migrated state is valid for the current struct.
pub fn autoRestore(self: anytype) void {
    const T = validatePersistType(@TypeOf(self.*), "autoRestore");
    const current_version = comptime schemaVersion(T);
    const stored_version = readVersion(self.base) orelse return;

    if (stored_version > current_version) {
        std.log.err(
            "gdzig: refusing to restore {s} persistence version {d} with older schema version {d}",
            .{ @typeName(T), stored_version, current_version },
        );
        return;
    }

    if (comptime current_version > 0) {
        if (stored_version < current_version) {
            var migration = Migration.init(self.base);
            defer migration.deinit();

            var from_version = stored_version;
            while (from_version < current_version) : (from_version += 1) {
                if (!runMigrationStep(T, from_version, &migration)) return;
            }

            if (!validateMigratedFields(T, &migration)) {
                std.log.err(
                    "gdzig: migration for {s} produced data incompatible with schema version {d}; original metadata retained",
                    .{ @typeName(T), current_version },
                );
                return;
            }

            migration.commit();
            writeVersion(self.base, current_version);
        }
    }

    const complete = restoreFields(self);
    if (complete and !hasPersistedPayload(self.base) and self.base.hasMeta(versionKey().*)) {
        self.base.removeMeta(versionKey().*);
    }
}

fn validatePersistType(comptime T: type, comptime operation: []const u8) type {
    const info = @typeInfo(T);
    if (info != .@"struct") {
        @compileError(operation ++ " expects a pointer to a struct, got " ++ @typeName(T));
    }
    if (!@hasField(T, "base")) {
        @compileError(operation ++ " requires a 'base' field in the struct");
    }
    return T;
}

fn schemaVersion(comptime T: type) u32 {
    const has_version = @hasDecl(T, "persist_version");
    const has_migration = @hasDecl(T, "migratePersisted");
    if (has_version != has_migration) {
        @compileError(@typeName(T) ++ " must declare persist_version and migratePersisted together");
    }
    if (!has_version) return 0;

    const version = T.persist_version;
    switch (@typeInfo(@TypeOf(version))) {
        .int, .comptime_int => {},
        else => @compileError(@typeName(T) ++ ".persist_version must be a positive integer"),
    }
    if (version <= 0 or version > std.math.maxInt(u32)) {
        @compileError(@typeName(T) ++ ".persist_version must fit in u32 and be greater than zero");
    }
    return @intCast(version);
}

fn runMigrationStep(comptime T: type, from_version: u32, migration: *Migration) bool {
    const result = T.migratePersisted(from_version, migration);
    const result_info = @typeInfo(@TypeOf(result));
    if (result_info != .error_union or result_info.error_union.payload != void) {
        @compileError(@typeName(T) ++ ".migratePersisted must return an error union with a void payload");
    }

    result catch |err| {
        std.log.err(
            "gdzig: migration for {s} from version {d} failed with {s}; original metadata retained",
            .{ @typeName(T), from_version, @errorName(err) },
        );
        return false;
    };
    return true;
}

fn validateMigratedFields(comptime T: type, migration: *const Migration) bool {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime !isPersistedField(field)) continue;

        if (comptime Variant.Tag.forTypeOrNull(field.type) != null) {
            if (migration.getVariant(field.name)) |raw_value| {
                var value = raw_value;
                defer value.deinit();

                if (value.as(field.type)) |decoded| {
                    var owned = decoded;
                    deinitOwnedValue(&owned);
                } else {
                    return false;
                }
            }
        }
    }
    return true;
}

fn restoreFields(self: anytype) bool {
    const T = @TypeOf(self.*);
    var complete = true;

    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime !isPersistedField(field)) continue;

        if (comptime Variant.Tag.forTypeOrNull(field.type) != null) {
            const key = StringName.fromComptimeLatin1(key_prefix ++ field.name);
            if (self.base.hasMeta(key.*)) {
                const val = self.base.getMeta(key.*, .{});
                defer val.deinit();

                if (val.as(field.type)) |decoded| {
                    deinitOwnedValue(&@field(self, field.name));
                    @field(self, field.name) = decoded;
                    self.base.removeMeta(key.*);
                } else {
                    complete = false;
                }
            }
        }
    }
    return complete;
}

fn isPersistedField(comptime field: std.builtin.Type.StructField) bool {
    if (std.mem.eql(u8, field.name, "base") or std.mem.eql(u8, field.name, "children")) return false;
    if (std.mem.eql(u8, field.name, "allocator")) return false;
    return !std.mem.startsWith(u8, field.name, "_");
}

fn fieldKey(comptime name: [:0]const u8) StringName {
    if (comptime name.len == 0 or std.mem.startsWith(u8, name, "_")) {
        @compileError("persisted field names must be non-empty and cannot start with '_'");
    }
    return StringName.fromLatin1(key_prefix ++ name, false);
}

fn readVersion(base: anytype) ?u32 {
    if (!base.hasMeta(versionKey().*)) return 0;

    const value = base.getMeta(versionKey().*, .{});
    defer value.deinit();
    const encoded = value.as(i64) orelse {
        std.log.err("gdzig: persisted schema version is not an integer; metadata retained", .{});
        return null;
    };
    if (encoded < 0 or encoded > std.math.maxInt(u32)) {
        std.log.err("gdzig: persisted schema version {d} is outside the u32 range; metadata retained", .{encoded});
        return null;
    }
    return @intCast(encoded);
}

fn writeVersion(base: anytype, version: u32) void {
    const encoded = Variant.init(i64, @intCast(version));
    defer encoded.deinit();
    base.setMeta(versionKey().*, encoded);
}

fn versionKey() *const StringName {
    return StringName.fromComptimeLatin1(key_prefix ++ "_version");
}

fn hasPersistedPayload(base: anytype) bool {
    var keys = base.getMetaList();
    defer keys.deinit();

    var index: i64 = 0;
    while (index < keys.size()) : (index += 1) {
        var encoded_key = keys.get(index);
        defer encoded_key.deinit();
        if (encoded_key.as(StringName)) |decoded_key| {
            var key = decoded_key;
            defer key.deinit();
            if (!key.eql(versionKey().*) and key.beginsWith(key_prefix)) return true;
        }
    }
    return false;
}

/// Release values for which assignment transfers ownership. Raw object
/// pointers are borrowed by convention and deliberately do not take this path;
/// builtins and `Gd` handles advertise ownership through `deinit`.
fn deinitOwnedValue(value: anytype) void {
    const T = std.meta.Child(@TypeOf(value));
    if (comptime gdzig.gd.isGd(T) or gdzig.gd.OptionalGd(T) != null) {
        gdzig.gd.releaseField(T, value);
        return;
    }

    switch (@typeInfo(T)) {
        .optional => if (value.*) |*payload| deinitOwnedValue(payload),
        .@"struct", .@"union", .@"enum", .@"opaque" => {
            if (comptime @hasDecl(T, "deinit")) value.deinit();
        },
        else => {},
    }
}
