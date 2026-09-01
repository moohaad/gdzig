//! Reaching other nodes without writing a cast.
//!
//! Godot's own accessors return `?*Node`, because that is all they can promise,
//! so getting at a node *as the type you want* used to end in a `castTo` you had
//! to write and get right at every call. There are four ways not to, and which
//! one applies depends only on what you know at compile time:
//!
//! | you know | use |
//! |---|---|
//! | the path and the type | `Child(T, "path")` |
//! | the target is the parent | `Parent(T)` |
//! | the path only at runtime | `getNodeAs(T, path)` |
//! | only that you want all the `T`s | `childrenAs(T)` |
//!
//! The first two are fields, resolved once before `_ready` and reported in the
//! log if the scene disagrees. The last two are calls, and answer with null or
//! with nothing rather than complaining -- a missing node or a child of another
//! type is the normal case there, not a mistake.
//!
//! The children below are built in `_enter_tree` rather than authored in a
//! `.tscn`, only so this file is self-contained. In a real project they would
//! come from the scene and nothing else here would change.

const TreeNode = @This();

allocator: Allocator,
base: *Control,

/// Known path, known type. Filled before `_ready`, so it is just a field by the
/// time anything reads it -- and if the scene ever stops having a `Title` that
/// is a `Label`, the log says which field and which path.
title: Child(Label, "Title") = .pending,

/// Whatever this node is parented to. `..` is Godot's own spelling for the
/// parent, so this is the same machinery as `Child` pointed one level up.
host: Parent(Node) = .pending,

/// The demo builds its examples by hand, so this takes the allocator the same
/// way its siblings do rather than letting gdzig synthesise one.
pub fn create(allocator: *Allocator) !*TreeNode {
    const self = try allocator.create(TreeNode);
    self.* = .{
        .allocator = allocator.*,
        .base = Control.init(),
    };
    self.base.setInstance(TreeNode, self);
    return self;
}

pub fn _enter_tree(self: *TreeNode) void {
    if (Engine.isEditorHint()) return;

    const title = Label.init();
    title.setName("Title");
    title.setPosition(.initXY(20, 20), .{});
    self.base.addChild(title, .{});

    // Two buttons and something that is not a button, so `childrenAs` has
    // something to skip.
    for ([_][:0]const u8{ "Alpha", "Beta" }, 0..) |name, i| {
        const button = Button.init();
        button.setName(name);
        button.setText(name);
        button.setPosition(.initXY(20, @floatFromInt(60 + i * 40)), .{});
        button.setSize(.initXY(120, 30), .{});
        self.base.addChild(button, .{});
    }

    const swatch = ColorRect.init();
    swatch.setName("Swatch");
    swatch.setPosition(.initXY(160, 60), .{});
    swatch.setSize(.initXY(60, 60), .{});
    swatch.setColor(.initRGBA(0.2, 0.6, 1, 1));
    self.base.addChild(swatch, .{});
}

pub fn _ready(self: *TreeNode) void {
    if (Engine.isEditorHint()) return;

    // 1. The field is already filled. No lookup, no cast, no null to unpack
    //    beyond the one that says the scene did not have it.
    if (self.title.get()) |label| {
        label.setText("Reached four ways, none of them a cast");
    }

    // 2. The parent, at the type this node expects to be under.
    if (self.host.get()) |parent| {
        std.log.info("tree: parented to a {s}", .{parent.getClass().toLatin1Buf(&class_buf)});
    }

    // 3. A path decided at runtime -- built here, but it could come from a
    //    property or a message. Null covers both "nothing there" and "not a
    //    Button", and neither prints an engine error.
    const wanted = if (self.base.getChildCount(.{}) > 2) "Beta" else "Alpha";
    if (self.base.getNodeAs(Button, wanted)) |button| {
        button.setText("found by path");
    }

    // 4. Every child that is a Button, with the Label and the ColorRect passed
    //    over. A mixed set of children is the ordinary case, so they are
    //    skipped rather than reported.
    var buttons = self.base.childrenAs(Button);
    var found: usize = 0;
    while (buttons.next()) |_| found += 1;

    std.log.info("tree: {d} of {d} children are buttons", .{ found, self.base.getChildCount(.{}) });
}

var class_buf: [64]u8 = undefined;

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const Child = godot.Child;
const Parent = godot.Parent;
const Registry = godot.extension.Registry;
const Button = godot.class.Button;
const ColorRect = godot.class.ColorRect;
const Control = godot.class.Control;
const Engine = godot.class.Engine;
const Label = godot.class.Label;
const Node = godot.class.Node;
