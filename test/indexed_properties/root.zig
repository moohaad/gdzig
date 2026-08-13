//! Named accessors for indexed properties.
//!
//! An indexed property is one whose accessor takes a magic constant:
//! `OmniLight3D.omni_range` is `getParam(4)`, and until these were generated
//! nothing in the Zig API said that 4 meant `.param_range`, nor stopped you
//! passing 5. The generated forwarder supplies the constant by name.
//!
//! This is codegen, so the cases are uniform and a few round-trips cover it.
//! What the round-trips are really checking is that each property forwards its
//! *own* index: a wrong constant would make two properties alias, and writing
//! one would silently change the other.

const std = @import("std");
const testing = std.testing;

test "properties sharing one accessor keep distinct indices" {
    var material = StandardMaterial3d.init();
    defer material.deinit();
    const m = material.get();

    // Three of the 25 properties behind `getFlag`/`setFlag`. Setting them to
    // different values is the point: if two forwarded the same constant, the
    // last write would win and one of these would come back wrong.
    m.setNoDepthTest(true);
    m.setDisableAmbientLight(false);
    m.setDisableFog(true);

    try testing.expect(m.getNoDepthTest());
    try testing.expect(!m.getDisableAmbientLight());
    try testing.expect(m.getDisableFog());

    m.setNoDepthTest(false);
    try testing.expect(!m.getNoDepthTest());
    // Unchanged by the write above.
    try testing.expect(m.getDisableFog());
}

test "a float indexed property round-trips through its named accessor" {
    const light = OmniLight3d.init();
    defer light.destroy();

    light.setOmniRange(12.5);
    light.setOmniAttenuation(0.75);

    try testing.expectEqual(@as(f64, 12.5), light.getOmniRange());
    try testing.expectEqual(@as(f64, 0.75), light.getOmniAttenuation());

    // And the named accessor agrees with the raw call it forwards to.
    try testing.expectEqual(light.getParam(.param_range), light.getOmniRange());
}

test "an inherited property reaches the class you can actually construct" {
    // `BaseMaterial3D` declares all 54 of these and is abstract; the accessors
    // would be unreachable if properties were not flattened into subclasses the
    // way methods are.
    var material = StandardMaterial3d.init();
    defer material.deinit();

    // Refcounted property type, so the getter returns an owning handle -- the
    // same convention as any other generated method returning a Resource.
    try testing.expectEqual(@as(?Gd(Texture2d), null), material.get().getAlbedoTexture());
}

test "a property whose setter is private gets a getter only" {
    // The four `Control.anchor_*` properties name `_set_anchor` as their setter,
    // which is private and never generated. Emitting `setAnchorLeft` would have
    // produced a call to a method that does not exist.
    try testing.expect(@hasDecl(Control, "getAnchorLeft"));
    try testing.expect(!@hasDecl(Control, "setAnchorLeft"));

    const control = Control.init();
    defer control.destroy();
    try testing.expectEqual(control.getAnchor(.side_left), control.getAnchorLeft());
}

test "numeric-suffix properties are skipped in favour of the indexed accessor" {
    // `AudioStreamPlaylist.stream_0` .. `stream_63` are 64 properties over one
    // accessor. `getListStream(37)` reads better than `getStream37()`, and 64
    // near-identical forwarders would be noise.
    try testing.expect(!@hasDecl(AudioStreamPlaylist, "getStream0"));
    try testing.expect(!@hasDecl(AudioStreamPlaylist, "getStream63"));
    try testing.expect(@hasDecl(AudioStreamPlaylist, "getListStream"));
}

const gdzig = @import("gdzig");
const Gd = gdzig.Gd;

const AudioStreamPlaylist = gdzig.class.AudioStreamPlaylist;
const Control = gdzig.class.Control;
const OmniLight3d = gdzig.class.OmniLight3d;
const StandardMaterial3d = gdzig.class.StandardMaterial3d;
const Texture2d = gdzig.class.Texture2d;
