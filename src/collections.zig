const std = @import("std");
const gdzig = @import("gdzig.zig");
const Array = gdzig.builtin.Array;
const Dictionary = gdzig.builtin.Dictionary;
const Variant = gdzig.builtin.Variant;
const StringName = gdzig.builtin.StringName;

/// Creates a Godot Array from a Zig tuple, array, or slice.
pub fn array(items: anytype) Array {
    const T = @TypeOf(items);
    const info = @typeInfo(T);
    
    var arr = Array.init();
    
    if (info == .@"struct" and info.@"struct".is_tuple) {
        inline for (info.@"struct".fields) |field| {
            const val = @field(items, field.name);
            const variant = toVariant(val);
            arr.append(variant);
            variant.deinit();
        }
    } else if (info == .array or info == .pointer) {
        for (items) |val| {
            const variant = toVariant(val);
            arr.append(variant);
            variant.deinit();
        }
    } else {
        @compileError("godot.array expects a tuple, array, or slice, got " ++ @typeName(T));
    }
    
    return arr;
}

/// Creates a Godot Dictionary from a Zig anonymous struct.
pub fn dict(struct_val: anytype) Dictionary {
    const T = @TypeOf(struct_val);
    const info = @typeInfo(T);
    
    if (info != .@"struct" or info.@"struct".is_tuple) {
        @compileError("godot.dict expects an anonymous struct, got " ++ @typeName(T));
    }
    
    var d = Dictionary.init();
    inline for (info.@"struct".fields) |field| {
        const key_str = StringName.fromComptimeLatin1(field.name);
        const key_variant = Variant.init(StringName, key_str.*);
        
        const val = @field(struct_val, field.name);
        const val_variant = toVariant(val);
        
        _ = d.set(key_variant, val_variant);
        
        // Ensure deinit of both variants and StringName if it allocates (fromComptimeLatin1 doesn't allocate StringName buffer but variant holds it)
        key_variant.deinit();
        val_variant.deinit();
    }
    return d;
}

fn toVariant(val: anytype) Variant {
    const VType = @TypeOf(val);
    if (VType == comptime_int) {
        return Variant.init(i64, val);
    } else if (VType == comptime_float) {
        return Variant.init(f64, val);
    } else {
        switch (@typeInfo(VType)) {
            .pointer => |p| {
                if (p.size == .slice and p.child == u8) {
                    const coerced = gdzig.coerceString(val);
                    defer coerced.deinit();
                    return Variant.init(gdzig.builtin.String, coerced.value);
                }
                if (p.size == .one) {
                    switch (@typeInfo(p.child)) {
                        .array => |a| {
                            if (a.child == u8) {
                                const coerced = gdzig.coerceString(val);
                                defer coerced.deinit();
                                return Variant.init(gdzig.builtin.String, coerced.value);
                            }
                        },
                        else => {}
                    }
                }
            },
            else => {}
        }
        return Variant.init(VType, val);
    }
}

