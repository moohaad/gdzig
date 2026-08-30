//! Forces every hand-written declaration to be compiled.
//!
//! Zig only analyses what something references, so a function nobody calls is
//! never type-checked. It can be committed, reviewed, released, and still not
//! build. `macros.zig` shipped with four such errors -- a `?type` read as a
//! `type`, and three uses of the managed `ArrayList` API -- and they surfaced
//! the moment a test finally named them, not before.
//!
//! `-Dsurface-audit` does this for the *generated* bindings. This is the same
//! idea for the code written by hand, and it costs a few lines rather than a
//! test per function.
//!
//! ## What it cannot reach
//!
//! Generic functions and types. `Pool(T)` has no body to analyse until some `T`
//! is chosen, and reflection cannot guess one -- which is exactly where three of
//! those four errors were. So the automatic sweep below is followed by a short
//! hand-written list, and anything generic that is added needs a line there.
//! That list is the part that goes stale; the sweep looks after itself.

pub fn register(_: *gdzig.extension.Registry) void {}

/// Names every non-generic public declaration of `Namespace`, which is enough
/// to make the compiler analyse each one.
fn touchAll(comptime Namespace: type) void {
    inline for (@typeInfo(Namespace).@"struct".decls) |decl| {
        const T = @TypeOf(@field(Namespace, decl.name));
        if (@typeInfo(T) == .@"fn" and !@typeInfo(T).@"fn".is_generic) {
            _ = &@field(Namespace, decl.name);
        }
    }
}

test "every hand-written module compiles" {
    // The generated namespaces are deliberately absent: `-Dsurface-audit`
    // covers those, and sweeping them here would repeat minutes of work.
    touchAll(gdzig.macros);
    touchAll(gdzig.collections);
    touchAll(gdzig.persist);
    touchAll(gdzig.signal_util);
    touchAll(gdzig.math);
    touchAll(gdzig.random);
    touchAll(gdzig.rpc);
    touchAll(gdzig.heap);
    touchAll(gdzig.input);
    touchAll(gdzig.gd);
}

test "every generic helper compiles at some instantiation" {
    // Hand-written because reflection cannot choose `T`. An entry here is worth
    // adding whenever a generic is: without one the type exists but its bodies
    // are never analysed, which is how `Pool` reached three compile errors.
    touchAll(gdzig.Pool(Node));
    touchAll(gdzig.EventBus(.{}));
    touchAll(gdzig.Children(Node));
    touchAll(gdzig.Child(Node, "Marker"));
    touchAll(gdzig.Parent(Node));
    touchAll(gdzig.Autoload(Node, "Bus"));
    touchAll(gdzig.Weak(Node));
    touchAll(gdzig.Gd(Resource));
    touchAll(gdzig.TweenBuilder);
}

const gdzig = @import("gdzig");
const Node = gdzig.class.Node;
const Resource = gdzig.class.Resource;
