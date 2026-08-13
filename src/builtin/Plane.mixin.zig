// `initABCD` is not usable here: it goes through the engine's constructor
// table, so it cannot be evaluated at comptime and a container-level constant
// needs a comptime-known initializer. `initNormalD` assigns the fields
// directly, as does `Vector3.initXYZ`, so both fold away.

/// Constructs a default-initialized [Plane](https://gdzig.github.io/gdzig/#gdzig.builtin.plane.Plane) with all components set to `0`.
pub const init: Plane = .initNormalD(.initXYZ(0, 0, 0), 0);

/// A plane that extends in the Y and Z axes (normal vector points +X).
pub const plane_yz: Plane = .initNormalD(.initXYZ(1, 0, 0), 0);
/// A plane that extends in the X and Z axes (normal vector points +Y).
pub const plane_xz: Plane = .initNormalD(.initXYZ(0, 1, 0), 0);
/// A plane that extends in the X and Y axes (normal vector points +Z).
pub const plane_xy: Plane = .initNormalD(.initXYZ(0, 0, 1), 0);

// @mixin stop

const Self = gdzig.builtin.Plane;

const gdzig = @import("gdzig");
const Plane = gdzig.builtin.Plane;
