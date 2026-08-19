# `asInstance` and identity: what the engine cannot answer

**Fixed.** `asInstance` now checks. This note is kept for the three routes that do
not work, each of which looks obvious and costs a day to rediscover.

## The hole, as it was

`castTo` to a user class returned a non-null pointer for an object that is not one:

```zig
const a = try ClassA.create();
gdzig.class.castTo(ClassC, a);     // non-null. A ClassA is not a ClassC.
gdzig.class.castTo(Unrelated, a);  // non-null. Shares no ancestry with ClassA.
```

Both are now `null`, guarded by `castTo refuses a class the object is not` in
`test/inheritance/root.zig`.

`castTo` with a struct target is `upcast(*Object, value).asInstance(T)`, and
`asInstance` is a bare instance-binding lookup keyed by `typeToken(T)`:

```zig
fn typeToken(comptime T: type) *anyopaque {
    return @ptrCast(&struct { var token: void = {}; comptime { _ = T; } }.token);
}
```

`var token: void` is zero-sized, so it has no storage and its address is `1` -- for every
`T`. Measured:

```
u8  tokens: A=anyopaque@7ff6fb1371c8 B=@..c9 C=@..ca   distinct
void tokens: A=anyopaque@1 B=anyopaque@1 C=anyopaque@1
```

Every class shares one token, so the lookup cannot miss, and whatever instance was bound
comes back typed as `*T`.

## Three fixes that do not work, each measured

**1. Give each type a real token (`var token: u8`) and bind the whole ancestor chain.**
Distinct addresses, and `setInstance` binds `upcast(*Ancestor, instance)` under each. Only
the first binding survives: Godot's `set_instance_binding` takes exactly one per object and
drops the rest. Traced -- tokens matched and the object matched, and the lookup still
missed:

```
set ClassC token=@..f9f1  obj=Object@1a9bf6f21b0
set ClassB token=@..fbc0  obj=Object@1a9bf6f21b0
get ClassB token=@..fbc0  obj=Object@1a9bf6f21b0  -> MISS
```

**2. Ask ClassDB for a class tag and use `objectCastTo`,** the way the opaque path in
`downcast` does. `classdb_get_classtag` returns null for an extension class:

```
asInstance(ClassB): tag=null castTo=null
```

**3. Ask the engine for the object's class name and use `ClassDB.is_parent_class`.**
The name Godot reports is not the extension class:

```
actual='Object' want='ClassB' isParent=false
```

`objectSetInstance` attaches the instance without making `object_get_class_name` report the
extension class, at least for an object built as `Object.init()` and then given an instance
-- which is what `test/inheritance` does and what `Synthesized.create` does.

## The route that worked

`DestroyInstanceBinding` (`src/extension/class.zig:138`) already keeps a per-object record,
pooled, reachable as `DestroyInstanceBinding.get(obj)`. It reaches it with
`objectGetInstanceBinding(obj, &callbacks, &callbacks)` -- a real address as the token, and
a create callback so Godot makes the binding on demand rather than requiring a `set`. That
is the mechanism the three attempts above needed and did not use: **lazy creation, not
`set_instance_binding`.**

That record now carries the most-derived type as an `extension.InstanceType`: a
comptime-unique id per class, plus a `narrow` generated per concrete class that walks the
real `upcast` chain. `asInstance(T)` refuses a wrong `T` and returns `upcast(*T, instance)`
rather than a reinterpreted pointer -- so it does not depend on the ancestor sitting at
offset 0 either, which Zig's field ordering does not promise.

One ordering trap, which cost a debugging round: `DestroyInstanceBinding.get` *creates* its
record via `get_instance_binding`, and Godot refuses `set_instance_binding` once an object
has any binding. Recording the type before binding the instance leaves the instance unbound
and every cast returning null. Bind first, record second.

`vtable.zig:74` still has the offset-0 assumption in its own path (`@ptrCast(p_instance)` to
`*Owner`); the fix there is `class.upcast`, and it is separate from this.
