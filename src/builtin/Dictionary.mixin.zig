/// Makes a Dictionary into a typed Dictionary.
///
/// - **K**: The type for Dictionary keys.
/// - **V**: The type for Dictionary values.
/// - **key_script**: An optional pointer to a Script object (if K is an object, and the base class is extended by a script).
/// - **value_script**: An optional pointer to a Script object (if V is an object, and the base class is extended by a script).
///
/// _Since Godot 4.4_
pub inline fn setTyped(
    self: *Array,
    comptime K: type,
    comptime V: type,
    key_script: ?*const Variant,
    value_script: ?*const Variant,
) void {
    const key_tag = Variant.Tag.forType(K);
    const value_tag = Variant.Tag.forType(V);
    const key_class_name = StringName.fromType(K);
    const value_class_name = StringName.fromType(V);

    raw.dictionarySetTyped(
        self.ptr(),
        @intFromEnum(key_tag),
        if (key_tag == .object) key_class_name.constPtr() else null,
        if (key_script) |s| s.constPtr() else null,
        @intFromEnum(value_tag),
        if (value_tag == .object) value_class_name.constPtr() else null,
        if (value_script) |s| s.constPtr() else null,
    );
}

/// Gets a pointer to a Variant in a Dictionary with the given key.
///
/// - **key**: A pointer to a Variant representing the key.
///
/// _Since Godot 4.1_
pub inline fn index(self: *Dictionary, key: *const Variant) *Variant {
    return @ptrCast(@alignCast(raw.dictionaryOperatorIndex(self.ptr(), key.constPtr())));
}

/// Gets a const pointer to a Variant in a Dictionary with the given key.
///
/// - **key**: A pointer to a Variant representing the key.
///
/// _Since Godot 4.1_
pub inline fn indexConst(self: *const Dictionary, key: *const Variant) *const Variant {
    return @ptrCast(@alignCast(raw.dictionaryOperatorIndexConst(self.constPtr(), key.constPtr())));
}

pub const Iterator = struct {
    dict: *const Dictionary,
    keys: Array,
    index: usize = 0,

    pub const Entry = struct {
        key: *const Variant,
        value: *const Variant,
    };

    pub fn next(self: *Iterator) ?Entry {
        const sz = self.keys.size();
        if (self.index < sz) {
            const key = self.keys.indexConst(self.index);
            const value = self.dict.indexConst(key);
            self.index += 1;
            return .{ .key = key, .value = value };
        }
        return null;
    }
    
    pub fn deinit(self: *Iterator) void {
        self.keys.deinit();
    }
};

/// Returns an iterator over the key-value pairs of the dictionary.
/// The returned iterator allocates an array of keys and MUST be `deinit()`ed.
pub inline fn iterator(self: *const Dictionary) Iterator {
    return .{ .dict = self, .keys = self.keys() };
}

// @mixin stop

const Self = gdzig.builtin.Dictionary;

const gdzig = @import("gdzig");
const raw = &gdzig.raw;
const Array = gdzig.builtin.Array;
const Dictionary = gdzig.builtin.Dictionary;
const StringName = gdzig.builtin.StringName;
const Variant = gdzig.builtin.Variant;
