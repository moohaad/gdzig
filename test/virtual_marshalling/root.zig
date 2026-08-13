//! Refcounted objects crossing the *virtual* ptrcall boundary.
//!
//! Godot treats them differently in a virtual than in a standard ptrcall: the
//! slot is a `Ref<T>*` rather than a `T**`, so it has to be read with
//! `ref_get_object` and populated with `ref_set_object` (godot-cpp#954).
//!
//! The return direction is the one that mattered, and only for a **borrowed**
//! `*T` return: writing the bare pointer set the engine's `Ref` without
//! incrementing, so it held a reference nobody had taken and the object was
//! freed the first time either side released it. The first test below fails
//! with `expected 2, found 1` against the old code.
//!
//! For an **owning** `Gd(T)` return the counts happened to balance -- the
//! missing increment and the missing release cancelled -- so the second test
//! passes either way and is not a regression test for that. It was still wrong:
//! `?Gd(T)` is 24 bytes and the slot is an 8-byte `Ref<T>*`, so the old path
//! overran the engine's stack by 16 bytes and got away with it.
//!
//! The argument direction was never wrong in practice -- `Ref<T>` holds exactly
//! one pointer, so reading it as a `T**` yields the same address -- but it now
//! goes through the documented accessor rather than relying on that layout.

const std = @import("std");
const testing = std.testing;

pub fn register(r: *gdzig.extension.Registry) void {
    _ = r.createClass(LendingTexture, {}, .auto);
    _ = r.createClass(CreatingTexture, {}, .auto);
    _ = r.createClass(RecordingMesh, {}, .auto);
}

fn ensureRegistered() void {
    const S = struct {
        var done: bool = false;
    };
    if (!S.done) {
        S.done = true;
        gdzig.testing.loadModule(@This());
    }
}

/// Returns an image it keeps owning, the borrowing convention: `*T` lends.
const LendingTexture = struct {
    base: *Texture2d,
    image: *Image,

    pub fn create() !*LendingTexture {
        const self = try allocator.create(LendingTexture);
        var base = Texture2d.init();
        var image = Image.create(2, 2, false, .format_rgba8).?;
        self.* = .{ .base = base.release(), .image = image.release() };
        self.base.setInstance(LendingTexture, self);
        return self;
    }

    pub fn destroy(self: *LendingTexture) void {
        allocator.destroy(self);
    }

    pub fn _getImage(self: *LendingTexture) ?*Image {
        return self.image;
    }
};

/// Makes a fresh image per call and hands it over, the owning convention:
/// `Gd(T)` transfers. This is the shape of `AudioStream._instantiate_playback`.
const CreatingTexture = struct {
    base: *Texture2d,

    pub fn create() !*CreatingTexture {
        const self = try allocator.create(CreatingTexture);
        var base = Texture2d.init();
        self.* = .{ .base = base.release() };
        self.base.setInstance(CreatingTexture, self);
        return self;
    }

    pub fn destroy(self: *CreatingTexture) void {
        allocator.destroy(self);
    }

    pub fn _getImage(_: *CreatingTexture) ?Gd(Image) {
        return Image.create(4, 4, false, .format_rgba8);
    }
};

/// Records the refcounted argument a virtual is handed.
const RecordingMesh = struct {
    base: *Mesh,
    seen: ?*Material = null,

    pub fn create() !*RecordingMesh {
        const self = try allocator.create(RecordingMesh);
        var base = Mesh.init();
        self.* = .{ .base = base.release() };
        self.base.setInstance(RecordingMesh, self);
        return self;
    }

    pub fn destroy(self: *RecordingMesh) void {
        allocator.destroy(self);
    }

    pub fn _surfaceSetMaterial(self: *RecordingMesh, _: i32, material: *Material) void {
        self.seen = material;
    }
};

test "a virtual lending a refcounted return leaves the engine holding its own reference" {
    ensureRegistered();

    const texture = try LendingTexture.create();
    const counter = RefCounted.upcast(texture.image);

    // The class holds the only reference so far.
    try testing.expectEqual(@as(i32, 1), counter.getReferenceCount());

    var got = texture.base.getImage().?;
    try testing.expectEqual(texture.image, got.get());

    // Two now: ours and the one the engine took on the way out. A 1 here is the
    // bug this test exists for -- the returned handle would own a reference
    // that was never taken, and releasing it would free an object the class
    // still points at.
    try testing.expectEqual(@as(i32, 2), counter.getReferenceCount());

    got.deinit();
    try testing.expectEqual(@as(i32, 1), counter.getReferenceCount());
}

test "a virtual handing over a refcounted return transfers, leaving one owner" {
    ensureRegistered();

    const texture = try CreatingTexture.create();

    var got = texture.base.getImage().?;
    // The virtual's handle was released as part of the hand-over, so the caller
    // is the sole owner. A 2 would mean the transfer leaked the original.
    //
    // This count is the same one the old code produced -- see the note at the
    // top -- so what this test locks in is that returning `Gd(T)` from a virtual
    // is supported and lands the caller with exactly one reference, not that the
    // marshalling was fixed.
    try testing.expectEqual(@as(i32, 1), RefCounted.upcast(got.get()).getReferenceCount());
    try testing.expectEqual(@as(i32, 4), got.get().getWidth());

    // Sole owner, so this frees it.
    got.deinit();
}

test "a virtual receives the refcounted argument it was passed" {
    ensureRegistered();

    const mesh = try RecordingMesh.create();
    var material = StandardMaterial3d.init();
    defer material.deinit();

    try testing.expect(mesh.seen == null);
    mesh.base.surfaceSetMaterial(0, Material.upcast(material.get()));
    try testing.expectEqual(Material.upcast(material.get()), mesh.seen.?);
}

const gdzig = @import("gdzig");
const Gd = gdzig.Gd;
const allocator = gdzig.testing.allocator;

const Image = gdzig.class.Image;
const Material = gdzig.class.Material;
const Mesh = gdzig.class.Mesh;
const RefCounted = gdzig.class.RefCounted;
const StandardMaterial3d = gdzig.class.StandardMaterial3d;
const Texture2d = gdzig.class.Texture2d;
