//! One test per marshalling shape, worked down the ranking that
//! `gdzig-api-audit shapes` produces.
//!
//! The premise is that marshalling defects cluster by shape rather than by
//! method: `getChildCount` and `getIndex` both return `i32` through identical
//! generated code, so covering one covers the other. Each test here therefore
//! stands in for every method sharing its shape, and the test name is the shape
//! so the mapping back to the worklist is direct.
//!
//! Round-trip wherever the API allows it -- set a value, read it back, assert
//! equality. A one-way call only proves the callee did not crash; a round-trip
//! is what catches a value mangled on the way out, which is how the sub-8-byte
//! ptrcall bug behaved.

const std = @import("std");
const testing = std.testing;

/// Fills the stack with a recognisable pattern so a return slot that is written
/// too narrowly leaves the poison behind instead of a plausible zero. Copied
/// rather than shared with `test/codegen`, which is a separate module.
noinline fn poisonStack() void {
    var buf: [8192]u8 = undefined;
    for (&buf) |*b| b.* = 0xAA;
    std.mem.doNotOptimizeAway(&buf);
}

// The two largest shapes, 2,809 methods between them.
test "object/builtin <- () and void <- (object/builtin)" {
    var mesh = ArrayMesh.init();
    defer mesh.deinit();

    const want: Aabb = .{
        .position = .initXYZ(1, 2, 3),
        .size = .initXYZ(4, 5, 6),
    };
    mesh.get().setCustomAabb(want);
    try testing.expectEqual(want, mesh.get().getCustomAabb());
}

test "void <- (bool)" {
    var grid = AStarGrid2d.init();
    defer grid.deinit();

    grid.get().setJumpingEnabled(true);
    try testing.expect(grid.get().isJumpingEnabled());

    grid.get().setJumpingEnabled(false);
    try testing.expect(!grid.get().isJumpingEnabled());
}

test "float <- () and void <- (float)" {
    var curve = Curve.init();
    defer curve.deinit();

    curve.get().setMinValue(-3.5);

    // A float return is 8 bytes and so is the slot, but poison it anyway: this
    // is the control for the narrow-return tests below.
    poisonStack();
    try testing.expectEqual(@as(f64, -3.5), curve.get().getMinValue());
}

test "void <- (int) and int <- () under poisoned stack" {
    var curve = Curve.init();
    defer curve.deinit();

    curve.get().setPointCount(3);

    // `i32` return through an `i64` ptrcall slot: the case that broke before.
    poisonStack();
    try testing.expectEqual(@as(i32, 3), curve.get().getPointCount());
}

test "int <- (int) under poisoned stack" {
    var rng = RandomNumberGenerator.init();
    defer rng.deinit();

    rng.get().setSeed(12345);

    poisonStack();
    const value = rng.get().randiRange(10, 20);
    try testing.expect(value >= 10 and value <= 20);
}

test "void <- (enum) and enum <- () under poisoned stack" {
    var grid = AStarGrid2d.init();
    defer grid.deinit();

    grid.get().setCellShape(.cell_shape_isometric_right);

    // Enums are `i32` in Zig and `i64` across ptrcall, so this is the narrow
    // return path again, with a value that is not zero and not the default.
    poisonStack();
    try testing.expectEqual(AStarGrid2d.CellShape.cell_shape_isometric_right, grid.get().getCellShape());
}

test "String <- ()" {
    var config = ConfigFile.init();
    defer config.deinit();

    var section: String = .fromLatin1("shapes");
    defer section.deinit();
    var key: String = .fromLatin1("answer");
    defer key.deinit();

    config.get().setValue(section, key, .init(i64, 42));

    var text = config.get().encodeToText();
    defer text.deinit();

    var buf: [256]u8 = undefined;
    const encoded = text.toUtf8Buf(&buf);
    try testing.expect(std.mem.indexOf(u8, encoded, "answer=42") != null);
}

test "object/builtin <- (int)" {
    var curve = Curve2d.init();
    defer curve.deinit();

    curve.get().addPoint(.initXY(1, 2), .{ .in = .initXY(3, 4) });
    try testing.expectEqual(Vector2.initXY(3, 4), curve.get().getPointIn(0));
}

test "void <- (String)" {
    const node = Node.init();
    defer node.destroy();

    var path: String = .fromLatin1("res://shapes/round_trip.tscn");
    defer path.deinit();
    node.setSceneFilePath(path);

    var read_back = node.getSceneFilePath();
    defer read_back.deinit();

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("res://shapes/round_trip.tscn", read_back.toUtf8Buf(&buf));
}

test "bool <- (int)" {
    var astar = AStar2d.init();
    defer astar.deinit();

    astar.get().addPoint(7, .initXY(1, 1), .{});
    try testing.expect(astar.get().hasPoint(7));
    try testing.expect(!astar.get().hasPoint(8));
}

test "bool <- (object/builtin) and void <- (bool, object/builtin)" {
    const parent = Node.init();
    defer parent.destroy();
    const child = Node.init();

    parent.addChild(child, .{});
    try testing.expect(parent.isAncestorOf(child));

    // Requires the ancestor relationship above, which is why the two shapes
    // share a test rather than each constructing its own tree.
    parent.setEditableInstance(child, true);
}

test "int <- (object/builtin)" {
    var rng = RandomNumberGenerator.init();
    defer rng.deinit();
    rng.get().setSeed(99);

    var weights: PackedFloat32Array = .init();
    defer weights.deinit();
    _ = weights.append(1.0);
    _ = weights.append(0.0);
    _ = weights.append(0.0);

    // Only index 0 carries any weight, so the draw is deterministic.
    poisonStack();
    try testing.expectEqual(@as(i64, 0), rng.get().randWeighted(weights));
}

test "void <- (float, object/builtin)" {
    var grid = AStarGrid2d.init();
    defer grid.deinit();

    grid.get().setRegion(.initXYWidthHeight(0, 0, 4, 4));
    grid.get().update();

    grid.get().fillWeightScaleRegion(.initXYWidthHeight(1, 1, 2, 2), 3.0);
    try testing.expectEqual(@as(f64, 3.0), grid.get().getPointWeightScale(.initXY(1, 1)));
}

test "typedarray <- ()" {
    var info = Engine.getCopyrightInfo();
    defer info.deinit();

    try testing.expect(info.size() > 0);
}

test "void <- (StringName)" {
    const control = Control.init();
    defer control.destroy();

    var variation: StringName = .fromLatin1("FlatButton", false);
    defer variation.deinit();
    control.setThemeTypeVariation(variation);

    var read_back = control.getThemeTypeVariation();
    defer read_back.deinit();

    var buf: [64]u8 = undefined;
    var as_string: String = .fromStringName(read_back);
    defer as_string.deinit();
    try testing.expectEqualStrings("FlatButton", as_string.toUtf8Buf(&buf));
}

test "String <- (int)" {
    // Unix epoch, so the answer does not depend on the clock.
    var date = Time.getDateStringFromUnixTime(0);
    defer date.deinit();

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01", date.toUtf8Buf(&buf));
}

test "float <- (object/builtin)" {
    const node = Node2d.init();
    defer node.destroy();

    // Straight ahead along +x from the origin is zero radians.
    poisonStack();
    try testing.expectApproxEqAbs(@as(f64, 0.0), node.getAngleTo(.initXY(1, 0)), 1e-9);
}

test "void <- (bool, int)" {
    var animation = Animation.init();
    defer animation.deinit();

    const track = animation.get().addTrack(.type_value, .{});
    try testing.expectEqual(@as(i32, 0), track);

    animation.get().trackSetEnabled(track, false);
    try testing.expect(!animation.get().trackIsEnabled(track));

    animation.get().trackSetEnabled(track, true);
    try testing.expect(animation.get().trackIsEnabled(track));
}

test "object/builtin <- (object/builtin)" {
    var image = Image.create(4, 4, false, .format_rgba8).?;
    defer image.deinit();

    const want: Color = .{ .r = 1, .g = 0.25, .b = 0.5, .a = 1 };
    image.get().setPixelv(.initXY(2, 3), want);
    const got = image.get().getPixelv(.initXY(2, 3));

    // RGBA8 keeps one byte per channel, so a float channel comes back
    // quantised -- 0.5 reads as 128/255. One step is the tolerance. The four
    // channels are given distinct values so a swapped component still fails.
    const step = 1.0 / 255.0;
    try testing.expectApproxEqAbs(want.r, got.r, step);
    try testing.expectApproxEqAbs(want.g, got.g, step);
    try testing.expectApproxEqAbs(want.b, got.b, step);
    try testing.expectApproxEqAbs(want.a, got.a, step);
}

test "object/builtin <- (int, object/builtin)" {
    var font = FontFile.init();
    defer font.deinit();

    // No glyphs have been cached, so the answer is an empty array; what is
    // under test is the two-argument marshalling, not the contents.
    var glyphs = font.get().getGlyphList(0, .initXY(16, 0));
    defer glyphs.deinit();

    try testing.expectEqual(@as(i64, 0), glyphs.size());
}

// Second tier: the shapes left standing after the batch above, none larger than
// 86 methods.

test "void <- (float, int), float <- (int), int <- (Variant, float, float?, int), Variant <- (int) and NodePath <- (int)" {
    var animation = Animation.init();
    defer animation.deinit();

    const track = animation.get().addTrack(.type_value, .{});

    // `trackInsertKey` is a shape of its own: a Variant argument alongside a
    // defaulted float. Omitting `transition` exercises the materialisation path.
    const key = animation.get().trackInsertKey(track, 1.0, .init(i64, 7), .{});

    animation.get().trackSetKeyTime(track, key, 2.5);

    poisonStack();
    try testing.expectEqual(@as(f64, 2.5), animation.get().trackGetKeyTime(track, key));

    // The value put in above, read back out through a Variant return slot.
    var value = animation.get().trackGetKeyValue(track, key);
    defer value.deinit();
    try testing.expectEqual(@as(i64, 7), value.as(i64).?);

    // And a NodePath return, which is its own shape again.
    var path: NodePath = .fromString(.fromLatin1("Sprite2D:position"));
    defer path.deinit();
    animation.get().trackSetPath(track, path);

    var read_path = animation.get().trackGetPath(track);
    defer read_path.deinit();
    var as_string: String = .fromNodePath(read_path);
    defer as_string.deinit();
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Sprite2D:position", as_string.toUtf8Buf(&buf));
}

test "void <- (String, int), String <- (int) and int <- (String)" {
    var mesh = ArrayMesh.init();
    defer mesh.deinit();

    // A surface has to exist before it can be named. The minimum is a vertex
    // array at ARRAY_VERTEX in an ARRAY_MAX-sized array.
    var vertices: PackedVector3Array = .init();
    defer vertices.deinit();
    _ = vertices.pushBack(.initXYZ(0, 0, 0));
    _ = vertices.pushBack(.initXYZ(1, 0, 0));
    _ = vertices.pushBack(.initXYZ(0, 1, 0));

    var arrays: Array = .init();
    defer arrays.deinit();
    _ = arrays.resize(@intFromEnum(Mesh.ArrayType.array_max));
    arrays.set(@intFromEnum(Mesh.ArrayType.array_vertex), .init(PackedVector3Array, vertices));

    mesh.get().addSurfaceFromArrays(.primitive_triangles, arrays, .{});

    var name: String = .fromLatin1("hull");
    defer name.deinit();
    mesh.get().surfaceSetName(0, name);

    var read_back = mesh.get().surfaceGetName(0);
    defer read_back.deinit();

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("hull", read_back.toUtf8Buf(&buf));

    // The same name back the other way: a String argument returning an index,
    // which is a shape of its own and one the named surface above can answer
    // honestly rather than with a -1 from an empty mesh.
    poisonStack();
    try testing.expectEqual(@as(i32, 0), mesh.get().surfaceFindByName(name));
}

test "enum <- (int) and void <- (enum, int) under poisoned stack" {
    var animation = Animation.init();
    defer animation.deinit();

    const track = animation.get().addTrack(.type_value, .{});
    poisonStack();
    try testing.expectEqual(Animation.TrackType.type_value, animation.get().trackGetType(track));

    animation.get().trackSetInterpolationType(track, .interpolation_cubic);
    poisonStack();
    try testing.expectEqual(
        Animation.InterpolationType.interpolation_cubic,
        animation.get().trackGetInterpolationType(track),
    );
}

test "void <- (enum, object/builtin) and object/builtin <- (enum)" {
    const particles = CpuParticles2d.init();
    defer particles.destroy();

    var curve = Curve.init();
    defer curve.deinit();

    // `setParamCurve` borrows (`*Curve`) while `getParamCurve` returns an owned
    // `?Gd(Curve)`, so this also exercises both sides of the Gd(T) convention.
    particles.setParamCurve(.param_angular_velocity, curve.get());

    var read_back = particles.getParamCurve(.param_angular_velocity).?;
    defer read_back.deinit();
    try testing.expectEqual(curve.get(), read_back.get());
}

test "void <- (typedarray): round-trip" {
    // A GLTF resource rather than the more obvious `CodeEdit.setStringDelimiters`:
    // constructing a CodeEdit segfaults under `--headless`, before any binding
    // is involved. Same shape, no display server.
    var skeleton = GltfSkeleton.init();
    defer skeleton.deinit();

    var bone: String = .fromLatin1("spine");
    defer bone.deinit();

    var names: Array = .init();
    defer names.deinit();
    names.pushBack(.init(String, bone));

    skeleton.get().setUniqueNames(names);

    var read_back = skeleton.get().getUniqueNames();
    defer read_back.deinit();
    try testing.expectEqual(@as(i64, 1), read_back.size());
}

// `bool <- (String)` needs no test of its own: the CodeHighlighter round-trip
// below calls `hasKeywordColor`, whose name belongs to that shape alone.
test "void <- (String, object/builtin) and object/builtin <- (String)" {
    var highlighter = CodeHighlighter.init();
    defer highlighter.deinit();

    var keyword: String = .fromLatin1("comptime");
    defer keyword.deinit();

    const want: Color = .{ .r = 1, .g = 0, .b = 0, .a = 1 };
    highlighter.get().addKeywordColor(keyword, want);

    try testing.expect(highlighter.get().hasKeywordColor(keyword));
    try testing.expectEqual(want, highlighter.get().getKeywordColor(keyword));

    // `Dictionary <- ()`, folded in here rather than given its own fixture.
    var colors = highlighter.get().getKeywordColors();
    defer colors.deinit();
    try testing.expectEqual(@as(i64, 1), colors.size());
}

test "void <- (NodePath) and NodePath <- ()" {
    // Control rather than AnimationPlayer: `AnimationPlayer.getRoot` shares its
    // name with `SceneTree.getRoot`, which has a different shape, so a call to
    // it cannot be attributed to either. Unique names keep the audit honest.
    const control = Control.init();
    defer control.destroy();

    var text: String = .fromLatin1("../Sibling");
    defer text.deinit();
    var path: NodePath = .fromString(text);
    defer path.deinit();

    control.setFocusNext(path);

    var read_back = control.getFocusNext();
    defer read_back.deinit();

    var as_string: String = .fromNodePath(read_back);
    defer as_string.deinit();

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("../Sibling", as_string.toUtf8Buf(&buf));
}

test "String <- (String): round-trip" {
    var plain: String = .fromLatin1("shape coverage");
    defer plain.deinit();

    var encoded = Marshalls.utf8ToBase64(plain);
    defer encoded.deinit();

    var decoded = Marshalls.base64ToUtf8(encoded);
    defer decoded.deinit();

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("shape coverage", decoded.toUtf8Buf(&buf));
}

test "enum <- (object/builtin) under poisoned stack" {
    var source = Image.create(2, 2, false, .format_rgba8).?;
    defer source.deinit();
    source.get().setPixelv(.initXY(0, 0), .{ .r = 0, .g = 1, .b = 0, .a = 1 });

    // Encoding and decoding through the same buffer keeps this self-contained:
    // no file on disk, and the enum return is a real OK rather than an error.
    var png = source.get().savePngToBuffer();
    defer png.deinit();

    var loaded = Image.create(1, 1, false, .format_rgba8).?;
    defer loaded.deinit();

    poisonStack();
    try testing.expectEqual(Error.ok, loaded.get().loadPngFromBuffer(png));
    try testing.expectEqual(@as(i32, 2), loaded.get().getWidth());
}

test "Array <- (): round-trip" {
    // An untyped `Array` return, distinct from `typedarray <- ()` above: the
    // generated code differs, so the shapes do too.
    var shortcut = Shortcut.init();
    defer shortcut.deinit();

    var events: Array = .init();
    defer events.deinit();
    _ = events.resize(2);

    shortcut.get().setEvents(events);

    var read_back = shortcut.get().getEvents();
    defer read_back.deinit();
    try testing.expectEqual(@as(i64, 2), read_back.size());
}

test "typedarray <- (object/builtin)" {
    var grid = AStarGrid2d.init();
    defer grid.deinit();

    grid.get().setRegion(.initXYWidthHeight(0, 0, 2, 2));
    grid.get().update();

    var points = grid.get().getPointDataInRegion(.initXYWidthHeight(0, 0, 2, 2));
    defer points.deinit();
    try testing.expectEqual(@as(i64, 4), points.size());
}

// A second pass, taken on a different principle from the first. The first
// worked straight down the ranking, which is right when nothing is covered.
// With 85% reached, method count alone stops being the argument: what is left
// is 2,441 methods, and 997 of them sit in shapes with a defaulted argument
// while 133 involve a flag -- the two marshalling paths that actually produced
// defects during the 0.16 work. Ranking within those is what the tests below
// follow.

test "flag <- () and void <- (flag)" {
    const control = Control.init();
    defer control.destroy();

    // A `packed struct(u32)` written into an `i64` argument slot and read back
    // out of an `i64` return slot. Flag layout is one of the paths that broke
    // before, and a bitmask is the return most likely to survive a truncation
    // looking plausible.
    const want: Control.SizeFlags = .{ .size_expand = true, .size_shrink_end = true };
    control.setHSizeFlags(want);

    poisonStack();
    try testing.expectEqual(want, control.getHSizeFlags());
}

test "enum <- (String)" {
    var config = ConfigFile.init();
    defer config.deinit();

    var section: String = .fromLatin1("shapes");
    defer section.deinit();
    var key: String = .fromLatin1("answer");
    defer key.deinit();
    var path: String = .fromLatin1("user://shapes_enum_from_string.cfg");
    defer path.deinit();
    var password: String = .fromLatin1("hunter2");
    defer password.deinit();

    config.get().setValue(section, key, .init(i64, 42));

    // Both halves return `Error`, so the round trip is through the filesystem
    // and the assertion is on the enum both times.
    poisonStack();
    try testing.expectEqual(Error.ok, config.get().saveEncryptedPass(path, password));

    var reread = ConfigFile.init();
    defer reread.deinit();

    poisonStack();
    try testing.expectEqual(Error.ok, reread.get().loadEncryptedPass(path, password));

    var value = reread.get().getValue(section, key, .{});
    defer value.deinit();
    try testing.expectEqual(@as(i64, 42), value.as(i64).?);
}

test "bool <- (enum) and void <- (bool, enum)" {
    var material = StandardMaterial3d.init();
    defer material.deinit();

    material.get().setFlag(.flag_albedo_from_vertex_color, true);
    poisonStack();
    try testing.expect(material.get().getFlag(.flag_albedo_from_vertex_color));

    material.get().setFlag(.flag_albedo_from_vertex_color, false);
    poisonStack();
    try testing.expect(!material.get().getFlag(.flag_albedo_from_vertex_color));
}

test "void <- (int?) with the default omitted and supplied" {
    var semaphore = Semaphore.init();
    defer semaphore.deinit();

    // The point is the defaulted argument, so post both ways and count what
    // comes back out: one post with `count` omitted plus one with `count = 3`
    // is four waits, and a default that failed to materialise as 1 changes the
    // total. `trySait` is the only way to observe it without blocking.
    semaphore.get().post(.{});
    semaphore.get().post(.{ .count = 3 });

    var taken: usize = 0;
    while (semaphore.get().tryWait()) taken += 1;
    try testing.expectEqual(@as(usize, 4), taken);
}

test "void <- (bool?)" {
    var tool = SurfaceTool.init();
    defer tool.deinit();

    tool.get().begin(.primitive_triangles);
    tool.get().addVertex(.initXYZ(0, 0, 0));
    tool.get().addVertex(.initXYZ(1, 0, 0));
    tool.get().addVertex(.initXYZ(0, 1, 0));

    // Omitting `flip` is the path under test; the commit afterwards is what
    // says the tool is still in a usable state.
    tool.get().generateNormals(.{});

    var mesh = tool.get().commit(.{}) orelse return error.CommitFailed;
    defer mesh.deinit();
    try testing.expectEqual(@as(i64, 1), mesh.get().getSurfaceCount());
}

test "int <- (int, object/builtin)" {
    var font = FontFile.init();
    defer font.deinit();

    // Nothing has been added to cache 0, so the answer is 0 -- but it arrives
    // through an `i32` return slot with a `Vector2i` argument alongside an int,
    // which is the shape.
    poisonStack();
    try testing.expectEqual(@as(i32, 0), font.get().getTextureCount(0, .initXY(16, 16)));
}

test "object/builtin <- (StringName)" {
    var animation = Animation.init();
    defer animation.deinit();

    var name: StringName = .fromLatin1("checkpoint", false);
    defer name.deinit();

    animation.get().addMarker(name, 1.5);

    const want: Color = .{ .r = 0.25, .g = 0.5, .b = 0.75, .a = 1 };
    animation.get().setMarkerColor(name, want);
    try testing.expectEqual(want, animation.get().getMarkerColor(name));
}

test "StringName <- (int) and void <- (StringName, int)" {
    var space = AnimationNodeBlendSpace1d.init();
    defer space.deinit();

    var point = AnimationNodeAnimation.init();
    defer point.deinit();

    space.get().addBlendPoint(point.get(), 0.5, .{});

    var name: StringName = .fromLatin1("left", false);
    defer name.deinit();
    space.get().setBlendPointName(0, name);

    var read_back = space.get().getBlendPointName(0);
    defer read_back.deinit();

    var buf: [64]u8 = undefined;
    var as_string: String = .fromStringName(read_back);
    defer as_string.deinit();
    try testing.expectEqualStrings("left", as_string.toUtf8Buf(&buf));
}

test "void <- (Dictionary)" {
    var highlighter = CodeHighlighter.init();
    defer highlighter.deinit();

    var keyword: String = .fromLatin1("defer");
    defer keyword.deinit();

    var colors: Dictionary = .init();
    defer colors.deinit();
    _ = colors.set(.init(String, keyword), .init(Color, .{ .r = 0, .g = 1, .b = 0, .a = 1 }));

    highlighter.get().setKeywordColors(colors);
    try testing.expect(highlighter.get().hasKeywordColor(keyword));

    var read_back = highlighter.get().getKeywordColors();
    defer read_back.deinit();
    try testing.expectEqual(@as(i64, 1), read_back.size());
}

test "int <- (enum)" {
    var style = StyleBoxFlat.init();
    defer style.deinit();

    style.get().setCornerRadius(.corner_top_right, 7);

    poisonStack();
    try testing.expectEqual(@as(i32, 7), style.get().getCornerRadius(.corner_top_right));
    // The other corners are untouched, which is what says the enum argument
    // selected a corner rather than being dropped.
    try testing.expectEqual(@as(i32, 0), style.get().getCornerRadius(.corner_top_left));
}

test "void <- (enum, float)" {
    var style = StyleBoxFlat.init();
    defer style.deinit();

    style.get().setExpandMargin(.side_bottom, 4.5);

    poisonStack();
    try testing.expectEqual(@as(f64, 4.5), style.get().getExpandMargin(.side_bottom));
    try testing.expectEqual(@as(f64, 0), style.get().getExpandMargin(.side_top));
}

test "void <- (bool?, object/builtin)" {
    var grid = AStarGrid2d.init();
    defer grid.deinit();

    grid.get().setRegion(.initXYWidthHeight(0, 0, 4, 4));
    grid.get().update();

    // `solid` defaults to true, so the first call asserts the default arrived
    // and the second asserts it can still be overridden.
    grid.get().setPointSolid(.initXY(1, 1), .{});
    try testing.expect(grid.get().isPointSolid(.initXY(1, 1)));

    grid.get().setPointSolid(.initXY(1, 1), .{ .solid = false });
    try testing.expect(!grid.get().isPointSolid(.initXY(1, 1)));
}

// Deliberately not covered, and the reason is the harness rather than the
// shapes. `void <- (object/builtin, object/builtin?)`, 49 methods: `void <- (object/builtin, object/builtin?)`, 49
// methods. Only eight classes have it -- EditorNode3DGizmo,
// NavigationMeshGenerator, OpenXRPlaneTracker, PhysicalBone3D, RigidBody2D,
// RigidBody3D, TileSetAtlasSource, Window -- and every one needs an editor,
// a physics space, or a display server. `RigidBody2D.init()` segfaults under
// `--headless` on construction alone, before any method is called. Reaching this
// shape means running the tests against a real display server, which is a
// change to the harness rather than another test.
//
// The same wall stops `object/builtin <- (int?)` and `int <- (int?)`, 53
// methods between them. Both are dominated by `DisplayServer`, whose static
// methods panic on `attempt to use null value` under `--headless` -- the
// singleton is absent, so the bind lookup returns null before any argument is
// marshalled. Tests for them were written, run, and removed; they would pass
// unchanged the day the suite has a display server.

const gdzig = @import("gdzig");

const Aabb = gdzig.builtin.Aabb;
const Array = gdzig.builtin.Array;
const Color = gdzig.builtin.Color;
const NodePath = gdzig.builtin.NodePath;
const PackedFloat32Array = gdzig.builtin.PackedFloat32Array;
const PackedVector3Array = gdzig.builtin.PackedVector3Array;
const String = gdzig.builtin.String;
const StringName = gdzig.builtin.StringName;
const Vector2 = gdzig.builtin.Vector2;

const Error = gdzig.global.Error;

const Animation = gdzig.class.Animation;
const ArrayMesh = gdzig.class.ArrayMesh;
const AStar2d = gdzig.class.AStar2d;
const AStarGrid2d = gdzig.class.AStarGrid2d;
const CodeHighlighter = gdzig.class.CodeHighlighter;
const ConfigFile = gdzig.class.ConfigFile;
const CpuParticles2d = gdzig.class.CpuParticles2d;
const Control = gdzig.class.Control;
const Curve = gdzig.class.Curve;
const Curve2d = gdzig.class.Curve2d;
const Engine = gdzig.class.Engine;
const FontFile = gdzig.class.FontFile;
const GltfSkeleton = gdzig.class.GltfSkeleton;
const Image = gdzig.class.Image;
const Marshalls = gdzig.class.Marshalls;
const Mesh = gdzig.class.Mesh;
const Node = gdzig.class.Node;
const Node2d = gdzig.class.Node2d;
const RandomNumberGenerator = gdzig.class.RandomNumberGenerator;
const Shortcut = gdzig.class.Shortcut;
const Time = gdzig.class.Time;
const AnimationNodeAnimation = gdzig.class.AnimationNodeAnimation;
const AnimationNodeBlendSpace1d = gdzig.class.AnimationNodeBlendSpace1d;
const Semaphore = gdzig.class.Semaphore;
const StandardMaterial3d = gdzig.class.StandardMaterial3d;
const StyleBoxFlat = gdzig.class.StyleBoxFlat;
const SurfaceTool = gdzig.class.SurfaceTool;
const Dictionary = gdzig.builtin.Dictionary;
