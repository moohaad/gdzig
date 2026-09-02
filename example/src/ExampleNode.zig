const ExampleNode = @This();

const Examples = [_]struct { name: [:0]const u8, T: type }{
    .{ .name = "Sprites", .T = SpritesNode },
    .{ .name = "GUI", .T = GuiNode },
    .{ .name = "Signals", .T = SignalNode },
    .{ .name = "Tree", .T = TreeNode },
};

/// Only the properties that need non-default options. A plain field binds on
/// its own, so listing one here with no options would say nothing.
pub const properties = .{
    .{ "property2", .{ .setter = .none } },
    .{ "speed", .{ .setter = .none } },
};

allocator: Allocator,
base: *Node,
panel: *PanelContainer = undefined,
example_node: ?Weak(Node) = null,

/// The `Config` singleton, filled before `_ready` like any other field.
/// `project.godot` loads it under that name; nothing here looks it up.
config: Autoload(ConfigNode, "Config") = .pending,

/// An exported resource that the class *owns*. A `?*Texture2d` would be a
/// borrow -- the reference could die underneath it -- so the field says
/// `Gd`, and gdzig references what it is given and releases it at teardown.
/// Nothing in `destroy` has to remember it.
banner: ?Gd(Texture2d) = null,

property1: Vector3 = .zero,
property2: Vector3 = .zero,
speed: f64 = 1.0,

fps_counter: *Label,

pub fn create(allocator: *Allocator) !*ExampleNode {
    const self = try allocator.create(ExampleNode);
    self.* = .{
        .allocator = allocator.*,
        .base = .init(),
        .fps_counter = .init(),
    };
    self.base.setInstance(ExampleNode, self);

    self.base.addChild(self.fps_counter, .{});
    self.fps_counter.setPosition(.{ .x = 50, .y = 50 }, .{});

    return self;
}

pub fn recreate(allocator: *Allocator, obj: *Object) *ExampleNode {
    const self = allocator.create(ExampleNode) catch @panic("OOM");
    self.* = .{
        .allocator = allocator.*,
        .base = @ptrCast(obj),
        .fps_counter = .init(),
    };
    self.base.setInstance(ExampleNode, self);
    return self;
}

pub fn destroy(self: *ExampleNode, allocator: *Allocator) void {
    std.log.info("destroy {s}", .{@typeName(ExampleNode)});
    godot.cleanup(self.base);
    allocator.destroy(self);
}

pub fn _process(self: *ExampleNode, _: f64) void {
    const window = self.base.getTree().?.getRoot().?;
    const sz = window.getSize();

    const label_size = self.fps_counter.getSize();
    self.fps_counter.setPosition(.{ .x = @floatFromInt(25), .y = @as(f32, @floatFromInt(sz.y - 25)) - label_size.y }, .{});

    var fps_string = String.empty;
    defer godot.cleanup(&fps_string);
    fps_string.print("FPS: {d}", .{Engine.getFramesPerSecond()}) catch @panic("Failed to format FPS");

    self.fps_counter.setText(fps_string);
}

fn clearScene(self: *ExampleNode) void {
    if (self.example_node) |handle| {
        // `onItemFocused` hands this node to the panel, so the panel owns it
        // and anything that frees the panel frees it too. Today `_exit_tree`
        // reliably gets here first, so a stored `*Node` would also work -- but
        // only because of that ordering, and nothing in the types said so.
        // The handle makes the assumption unnecessary instead of load-bearing.
        if (handle.get()) |node| godot.cleanup(node);
        self.example_node = null;
    }
}

/// What the callback path spells as a second function.
fn afterDelay(self: *ExampleNode, seconds: f64) void {
    coro.wait(self.base, seconds, .{});
    self.onTimeout();
}

pub fn onTimeout(_: *ExampleNode) void {}

pub fn onResized(_: *ExampleNode) void {}

pub fn getSpeed(self: *ExampleNode) f64 {
    return self.speed;
}

pub fn onItemFocused(self: *ExampleNode, idx: ?i64) void {
    if (idx == null) return;
    const real_idx = idx.?;
    std.log.info("on_item_focused: {}", .{real_idx});
    self.clearScene();
    switch (real_idx) {
        inline 0...Examples.len - 1 => |i| {
            const n = Examples[i].T.create(&self.allocator) catch unreachable;
            self.example_node = .init(n);
            self.panel.addChild(n, .{});
            self.panel.grabFocus(.{});
        },
        else => {},
    }
}

pub fn _enter_tree(self: *ExampleNode) void {
    // test T -> variant -> T
    const obj = ExampleNode.create(&self.allocator) catch unreachable;
    defer obj.destroy(&self.allocator);

    const variant: Variant = .init(*ExampleNode, obj);
    const result = variant.as(*ExampleNode).?;
    _ = result;

    // test Type-Safe Scene Instantiation
    if (godot.instantiateAs(ConfigNode, "res://config.tscn")) |config_node| {
        std.log.info("Successfully instantiated config.tscn via instantiateAs", .{});
        godot.cleanup(config_node.base);
    }

    // test Idiomatic Iterators
    var test_array = godot.builtin.Array.init();
    defer godot.cleanup(&test_array);
    test_array.append(.init(i64, 42));
    test_array.append(.init(i64, 100));
    var arr_it = test_array.iterator();
    while (arr_it.next()) |item| {
        std.log.info("Array item: {d}", .{item.as(i64).?});
    }

    // Generated from the project's Input Map, so renaming or removing one in
    // Godot turns this into a compile error instead of a silent runtime miss.
    if (godot.input.isActionPressed(godot.input.Action.jump)) {
        std.log.info("jump pressed!", .{});
    }
    if (godot.input.isActionPressed(godot.input.Action.move_up)) {
        std.log.info("move_up pressed!", .{});
    }

    //initialize fields
    self.example_node = null;
    self.property1 = Vector3.initXYZ(111, 111, 111);
    self.property2 = Vector3.initXYZ(222, 222, 222);

    if (Engine.isEditorHint()) {
        return;
    }

    const window_size = self.base.getTree().?.getRoot().?.getSize();

    var sp = HSplitContainer.init();
    sp.setHSizeFlags(.size_expand_fill);
    sp.setVSizeFlags(.size_expand_fill);
    sp.setSplitOffset(@intFromFloat(@as(f32, @floatFromInt(window_size.x)) * 0.2));
    sp.setAnchorsPreset(.preset_full_rect, .{});

    var itemList = ItemList.init();
    inline for (0..Examples.len) |i| {
        _ = itemList.addItem(Examples[i].name, .{});
    }

    // Reading the owning field above. `gd.get` unwraps the optional and
    // borrows in one step; spelled out it is `if (self.banner) |h| h.get()`,
    // which says the same thing twice at every read site. The result borrows,
    // so there is nothing to release here.
    if (gd.get(self.banner)) |banner| {
        std.log.info("banner is {d}x{d}", .{ banner.getWidth(), banner.getHeight() });
    } else {
        std.log.info("no banner assigned", .{});
    }

    // The delay comes from the autoload rather than a literal, which is the
    // point of reaching one at all.
    const delay = if (self.config.get()) |config| config.startup_delay else 1.0;

    if (comptime coro.supported) {
        // Straight-line: the wait is a statement, and what follows it is just
        // the next line. No second function, no connection to unpick.
        coro.spawn(self.allocator, afterDelay, .{ self, delay }) catch |err|
            std.log.err("example: {s}", .{@errorName(err)});
    } else {
        // The same wait where coroutines are not supported yet, which is every
        // platform but Windows. This is the shape `coro` exists to replace.
        var timer = self.base.getTree().?.createTimer(delay, .{}).?;
        defer timer.deinit();
        timer.get().connect(SceneTreeTimer.Timeout, self, &onTimeout);
    }
    sp.connect(HSplitContainer.Resized, self, &onResized);
    itemList.connect(ItemList.ItemSelected, self, &onItemFocused);

    self.panel = PanelContainer.init();
    self.panel.setHSizeFlags(.{ .size_fill = true });
    self.panel.setVSizeFlags(.{ .size_fill = true });
    self.panel.setFocusMode(.focus_all);

    sp.addChild(itemList, .{});
    sp.addChild(self.panel, .{});
    self.base.addChild(sp, .{});

    const vprt = self.base.getViewport().?;

    var tex = vprt.getTexture().?;
    defer tex.deinit();

    // A viewport texture has no image under `--headless`: the dummy renderer
    // has nothing to read back. Unwrapping it took the process down the first
    // time the example was run that way, which was only once the run step
    // started forwarding arguments.
    var img = tex.get().getImage() orelse return;
    defer img.deinit();

    const data = img.get().getData();
    _ = data;
}

pub fn _exit_tree(self: *ExampleNode) void {
    self.clearScene();
}

pub fn _notification(self: *ExampleNode, what: i32, _: bool) void {
    if (what == Node.NOTIFICATION_WM_CLOSE_REQUEST) {
        if (!Engine.isEditorHint()) {
            self.base.getTree().?.quit(.{});
        }
    }
}

pub fn _to_string(_: *ExampleNode) ?String {
    return String.fromLatin1("ExampleNode");
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const godot = @import("godot");
const coro = godot.coro;
const Autoload = godot.Autoload;
const Gd = godot.Gd;
const gd = godot.gd;
const Registry = godot.extension.Registry;
const Engine = godot.class.Engine;
const HSplitContainer = godot.class.HSplitContainer;
const ItemList = godot.class.ItemList;
const Label = godot.class.Label;
const Node = godot.class.Node;
const Weak = godot.Weak;
const Object = godot.class.Object;
const PanelContainer = godot.class.PanelContainer;
const String = godot.builtin.String;
const Variant = godot.builtin.Variant;
const Vector3 = godot.builtin.Vector3;
const Image = godot.class.Image;
const SceneTreeTimer = godot.class.SceneTreeTimer;
const Texture2d = godot.class.Texture2d;
const ViewportTexture = godot.class.ViewportTexture;

const ConfigNode = @import("ConfigNode.zig");
const GuiNode = @import("GuiNode.zig");
const SignalNode = @import("SignalNode.zig");
const TreeNode = @import("TreeNode.zig");
const SpritesNode = @import("SpriteNode.zig");
