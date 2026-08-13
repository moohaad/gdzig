//! Native structures: plain C structs the engine passes by pointer.
//!
//! These appear in the signatures of virtual methods an extension
//! implements, such as `AudioStreamPlayback._mix`.

pub const AudioFrame = extern struct {
    left: f32,
    right: f32,
};

pub const CaretInfo = extern struct {
    leading_caret: Rect2,
    trailing_caret: Rect2,
    leading_direction: TextServer.Direction,
    trailing_direction: TextServer.Direction,
};

pub const Glyph = extern struct {
    start: i32 = -1,
    end: i32 = -1,
    count: u8 = 0,
    repeat: u8 = 1,
    flags: u16 = 0,
    x_off: f32 = 0.0,
    y_off: f32 = 0.0,
    advance: f32 = 0.0,
    font_rid: Rid,
    font_size: i32 = 0,
    index: i32 = 0,
};

pub const ObjectId = extern struct {
    id: u64 = 0,
};

pub const PhysicsServer2dExtensionMotionResult = extern struct {
    travel: Vector2,
    remainder: Vector2,
    collision_point: Vector2,
    collision_normal: Vector2,
    collider_velocity: Vector2,
    collision_depth: f32,
    collision_safe_fraction: f32,
    collision_unsafe_fraction: f32,
    collision_local_shape: i32,
    collider_id: ObjectId,
    collider: Rid,
    collider_shape: i32,
};

pub const PhysicsServer2dExtensionRayResult = extern struct {
    position: Vector2,
    normal: Vector2,
    rid: Rid,
    collider_id: ObjectId,
    collider: ?*Object,
    shape: i32,
};

pub const PhysicsServer2dExtensionShapeRestInfo = extern struct {
    point: Vector2,
    normal: Vector2,
    rid: Rid,
    collider_id: ObjectId,
    shape: i32,
    linear_velocity: Vector2,
};

pub const PhysicsServer2dExtensionShapeResult = extern struct {
    rid: Rid,
    collider_id: ObjectId,
    collider: ?*Object,
    shape: i32,
};

pub const PhysicsServer3dExtensionMotionCollision = extern struct {
    position: Vector3,
    normal: Vector3,
    collider_velocity: Vector3,
    collider_angular_velocity: Vector3,
    depth: f32,
    local_shape: i32,
    collider_id: ObjectId,
    collider: Rid,
    collider_shape: i32,
};

pub const PhysicsServer3dExtensionMotionResult = extern struct {
    travel: Vector3,
    remainder: Vector3,
    collision_depth: f32,
    collision_safe_fraction: f32,
    collision_unsafe_fraction: f32,
    collisions: [32]PhysicsServer3dExtensionMotionCollision,
    collision_count: i32,
};

pub const PhysicsServer3dExtensionRayResult = extern struct {
    position: Vector3,
    normal: Vector3,
    rid: Rid,
    collider_id: ObjectId,
    collider: ?*Object,
    shape: i32,
    face_index: i32,
};

pub const PhysicsServer3dExtensionShapeRestInfo = extern struct {
    point: Vector3,
    normal: Vector3,
    rid: Rid,
    collider_id: ObjectId,
    shape: i32,
    linear_velocity: Vector3,
};

pub const PhysicsServer3dExtensionShapeResult = extern struct {
    rid: Rid,
    collider_id: ObjectId,
    collider: ?*Object,
    shape: i32,
};

pub const ScriptLanguageExtensionProfilingInfo = extern struct {
    signature: StringName,
    call_count: u64,
    total_time: u64,
    self_time: u64,
};

const gdzig = @import("gdzig.zig");
const Rect2 = gdzig.builtin.Rect2;
const TextServer = gdzig.class.TextServer;
const Rid = gdzig.builtin.Rid;
const Vector2 = gdzig.builtin.Vector2;
const Object = gdzig.class.Object;
const Vector3 = gdzig.builtin.Vector3;
const StringName = gdzig.builtin.StringName;
