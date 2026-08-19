# Plan: runtime coverage, indexed properties, and the fate of `Gd(T)`

Three pieces of work left over from the Zig 0.16 and Godot 4.7 branch. They are independent
and can be taken in any order, but they are listed by value: the first addresses where defects
actually are, the second is a bounded feature, the third is a decision that should not be left
half-made.

---

## 1. Runtime coverage

### The problem, stated honestly

The surface sweep proves every generated declaration type-checks. The coverage tool says how
many have ever *run*: **24 of 11,300** class-method names, 0.2%.

That gap is where this codebase's defects live. Every marshalling bug found during the 0.16
work — sub-8-byte ptrcall widths, nullable argument materialisation, virtual scalar widths,
flag layout, the six `Variant` methods passing `&self` — was invisible to the compiler and only
observable when a call crossed the FFI boundary.

### Why "write more tests" is not the plan

There are 16,822 class methods. Testing them individually is not going to happen, and the
attempt would produce a suite nobody maintains.

The useful observation is that **marshalling bugs cluster by signature shape, not by method**.
`getChildCount` returning `i32` and `getIndex` returning `i32` exercise the same code path; if
one is right, both are. So the unit worth covering is the distinct *marshalling shape* — the
set of type kinds involved in a call.

Measured across 4.7 by `gdzig-api-audit shapes`:

| | count |
| --- | ---: |
| class methods | 16,822 |
| **distinct marshalling shapes** | **784** |

And they are heavily skewed:

| shapes tested | methods whose path is exercised | |
| ---: | ---: | ---: |
| 10 | 9,470 | 56.3% |
| 25 | 12,764 | 75.9% |
| 50 | 14,327 | 85.2% |
| 100 | 15,303 | 91.0% |
| 200 | 15,957 | 94.9% |

**Fifty tests reach 85% of the method surface.** That is a bounded piece of work with a
defensible stopping point, which "test more methods" never had.

> **Revised from the original draft**, which said 459 shapes and 88% at fifty. Those numbers
> came from a shape key that pooled the return kind into the same set as the argument kinds, so
> a method *returning* an object shared a shape with one *taking* an object — which would let a
> return-side defect hide behind an argument-side test, and the sub-8-byte ptrcall bug was
> return-only. Separating them, and tracking `has_default` per argument rather than per method,
> costs 325 shapes and about three points of reach at fifty. The draft's "1,164 distinct full
> signatures" row was mislabelled: it is the same kind-based key with argument order preserved,
> not a count of raw type signatures, so it has been dropped rather than corrected.

### Steps

**1.1 Teach the audit tool to report shapes.** ✅ **Done** — `pkg/apiaudit/shapes.zig`:

```sh
zig build audit && ./zig-out/bin/gdzig-api-audit shapes zig-out/vendor/extension_api.json test
```

Ranks shapes by method count and, given test directories, marks which are exercised, printing
the highest-value uncovered ones. That list is the worklist for 1.2, and afterwards the thing
that says whether a new Godot version introduced a shape nothing covers.

The shape key is the return type's kind, plus the *set* of `(kind, has_default)` pairs over the
arguments, plus a vararg flag. Kinds are `int`, `float`, `bool`, `enum`, `flag`, `String`,
`StringName`, `NodePath`, `Variant`, `Array`, `Dictionary`, `typedarray`, `pointer`,
`object/builtin`, `void`. Rendered as `int <- (String, enum?)`, where `?` marks a defaulted
argument.

Three choices in that key each answer to a bug that has already happened: the return kind stays
separate from the argument kinds (the sub-8-byte ptrcall bug was return-only); `has_default` is
per argument, which puts `FileAccess.get_csv_line(delim = ",")` — the silently-discarded
non-empty default — in a shape by itself; and argument order and arity are dropped, since two
`Vector2` arguments marshal the same way one does.

Coverage is deliberately under-reported. The scan is textual and cannot tell `Node.getName`
from `Translation.getName`, so a called name only marks a shape when it occurs in exactly one;
ambiguous hits are counted as uncovered and reported separately. Over-reporting would silently
drop untested shapes off the worklist, which is the one error worth avoiding here.

The state when this landed, before 1.2: **16 of 784 shapes exercised, 3,712 of 16,822 methods
(22.1%)**, with 15 more shapes (25.5%) reached only ambiguously, and the two largest uncovered
shapes being `object/builtin <- ()` (1,409 methods) and `void <- (object/builtin)` (1,400).

**1.2 Cover the top shapes.** ✅ **Done** — `test/shapes/root.zig`, 31 tests.

Worked down the ranked list, round-tripping wherever the API allowed it. **62 of 784 shapes
exercised, 14,325 of 16,822 methods (85.2%)**, up from 16 shapes and 22.1%. The largest
uncovered shape fell from 1,409 methods to 56.

Two things worth knowing for the next pass:

*Pick methods whose name is unique to their shape.* The audit attributes a call only when the
name occurs in exactly one shape, so `AStar2D.getPointWeightScale` earns nothing —
`AStarGrid2D.getPointWeightScale` takes a `Vector2i` and sits in a different shape. Four tests
in the first draft exercised their shape at runtime but could not be credited, and were
rewritten against unambiguous methods. This is the conservative rule working: it would rather
under-report than let an untested shape drop off the list.

*Check the class constructs under `--headless` before building a test around it.*
`CodeEdit.init()` and `RigidBody2D.init()` both segfault there, on construction alone, before
any binding is involved. Substitutes exist for most shapes; where one does not, say so.

**Deliberately uncovered:** `void <- (object/builtin, object/builtin?)`, 49 methods. Only eight
classes have that shape — EditorNode3DGizmo, NavigationMeshGenerator, OpenXRPlaneTracker,
PhysicalBone3D, RigidBody2D, RigidBody3D, TileSetAtlasSource, Window — and every one needs an
editor, a physics space, or a display server. Reaching it means running the suite against a
real display server, which is a harness change rather than another test.

The next 50 shapes buy about 6% and cost the same as the first 50, so 85% is where this stops
until something makes the case for more.

**1.2b A second pass, on a different principle.** ✅ **Done** — 13 more tests, **86 of 784
shapes exercised, 14,876 of 16,822 methods (88.4%)**, up from 66 and 85.5%.

The case for going further was not the 6%. With 85% reached, method count stops being the
argument: of the 2,441 methods still uncovered, **997 sat in shapes with a defaulted argument
and 133 involved a flag** — the two marshalling paths that actually produced defects during the
0.16 work, and the two least covered. Ranking within those, rather than by raw count, is what
this pass followed.

The `--top=N` option was added to `shapes` to ask that question at all; the default 25 is a
worklist, and the composition of the remaining tail is a different question.

Two tests were written, run, and removed: `int <- (int?)` and `object/builtin <- (int?)`, 53
methods, both dominated by `DisplayServer`. Its static methods panic on `attempt to use null
value` under `--headless` — the singleton is absent, so the bind lookup returns null before any
argument is marshalled. That is the same wall as the deliberately-uncovered shape above, and
the tests are recorded in the file's closing comment so the next person does not rediscover it.

The CI floor moved 84 → 87 to hold the gain.

**1.3 Poison the stack.** ✅ **Done** — eight of the shape tests call `poisonStack()` before
the read-back, covering every scalar and enum return among them. Without it a narrow return
leaves the adjacent bytes intact and the test passes by luck, which is exactly how the
sub-8-byte bug survived.

**1.4 Report the number.** ✅ **Done** — `shapes` reports it, and `coverage` now closes by
pointing at `shapes`, since a per-method count is the wrong unit for deciding what to test
next. "24 of 11,300 methods" is technically true and useless; "62 of 784 shapes, covering
85.2% of methods" is actionable.

### Risk

Shape equivalence is an assumption, not a proof. Two methods sharing a shape share a
marshalling path *as currently generated*; a future codegen change could special-case one and
not the other. The mitigation is that 1.1 recomputes shapes from the API each run, so the
worklist tracks reality rather than a snapshot.

---

## 2. Indexed properties — done

### Scope

4,162 properties exist and none are emitted as declarations. The number overstates the gap:
for the 3,729 without an index, `setSyncMode`/`getSyncMode` are already generated, so a
property declaration would be naming sugar.

The real gap is the **433 indexed** properties, where the accessor exists but takes a magic
constant. `AreaLight3D.area_range` means calling `getParam(4)`. Nothing in the Zig API says
that 4 is `PARAM_AREA_RANGE`, and nothing stops you passing 5.

### What the data says about the design

Two questions had to be answered before this was worth planning; both now are.

**Collisions: none.** Of all 433, zero have a `get_<name>` or `set_<name>` that already exists
as a method on the same class. The obvious naming scheme is free, and `Class.hasCollision` is
not needed here.

**Not all 433 deserve an accessor.** 358 have distinct names (`area_range`, `emission_shape`).
The other 75 are numeric suffixes over an array — `AudioStreamPlaylist.stream_0` through
`stream_63`, all backed by `get_list_stream(index)`. Generating 64 near-identical accessors
for that is noise; `getListStream(i)` already reads better than `getStream37()`.

Worst offenders, one accessor backing many properties:

| properties | accessor |
| ---: | --- |
| 64 | `AudioStreamPlaylist.get_list_stream` |
| 25 | `BaseMaterial3D.get_flag` |
| 19 | `BaseMaterial3D.get_texture` |
| 17 | `ParticleProcessMaterial.get_param` |

`BaseMaterial3D.get_flag` is the interesting counterexample: 25 properties, all distinctly
named, all worth accessors. So the filter is the numeric suffix, not the sharing.

### Steps — ✅ all done

**2.1 `writeClassProperty`** in `codegen.zig`, plus **2.3** enabling the loop. Every named
indexed property gets a getter, and a setter where a public one exists:

```zig
/// The `omni_range` property: `getParam` with its index fixed to `.param_range`.
pub fn getOmniRange(self: *const OmniLight3d) f64 {
    return self.getParam(.param_range);
}
```

The enum member, not `@enumFromInt(4)` — that was the point of the exercise. All 358 index
arguments turned out to be enum-typed with a member matching the index, so the fallback never
fires. Where Godot aliases several names onto one value the first-declared one is used, because
`writeEnum` emits only that one as a tag.

**2.2 Numeric-suffix properties skipped**, with the reasoning in the source rather than left to
look like an oversight.

**2.4 Tests** in `test/indexed_properties/root.zig`, five of them. The round-trips deliberately
set *several* properties sharing one accessor to different values: a wrong constant would make
two properties alias, so writing one would silently change the other, and a single-property
round-trip would not notice.

### Two things the plan above had wrong

**Properties are not inherited, and that mattered more than the property count suggested.**
`Class.zig` collected only a class's own properties, while methods have always been flattened
into every subclass. `BaseMaterial3D` declares 54 indexed properties and is **abstract**;
`StandardMaterial3D`, the one you can construct, declares none. Generating from own properties
alone put those 54 accessors on a type nobody instantiates. Flattening properties the same way
methods are takes the output from 712 accessors across 26 classes to **2,920 across 119**.

**`AreaLight3D.area_range` is `PARAM_RANGE`, not `PARAM_AREA_RANGE`.** There is no such member;
index 4 of `Light3D.Param` is `PARAM_RANGE`. The generated code is right and the example in the
draft was not.

### What is emitted

| | count |
| --- | ---: |
| indexed properties, named | 358 |
| … with a public setter | 354 |
| generated getters (after flattening) | 1,612 |
| generated setters (after flattening) | 1,308 |
| classes touched | 119 |

The four without a setter are `Control.anchor_left/top/right/bottom`, which name the private
`_set_anchor`; they get a getter only, and a test asserts `setAnchorLeft` does *not* exist.

### Non-goal

The 3,729 non-indexed properties. Their accessors already exist and work. Emitting declarations
for them is a large diff for naming preference, and it would put ~4,000 more names into classes
that already collide often enough to need `hasCollision`.

---

## 3. `Gd(T)` — adopted (done)

**Decision: adopt, everywhere a refcounted object is handed to the caller.** Generated methods
returning a refcounted class return `?Gd(T)` — 562 distinct API methods, which the flattened
per-class surface re-emits as 3,359 signatures across 817 files — and the constructors of the
661 refcounted classes return `Gd(T)`.

### The convention, and why it is the engine's own

Ownership across the ptrcall boundary is not symmetric, so the binding is not either:

* **Returns are owned.** Godot hands back a `Ref<T>` whose count it has already incremented,
  so the handle **adopts** that reference rather than taking a second. Confirmed against
  godot-rust, which skips its refcount bump exactly when the static return type is refcounted
  (`adjust_refcount_on_ptrcall_return` increments only for a non-refcounted static type such as
  `Object`, where the pointer really is borrowed).
* **Constructors are owned.** `T.init()` already consumed Godot's "pending" initial reference
  (mirroring `Ref<T>::instantiate()`), so it too hands the caller a reference it owes.
* **Arguments are borrowed.** Godot takes `const Ref<T>&`; the caller keeps ownership. `*T` was
  already the right signature, so the planned "arguments second" step dissolved — there was
  nothing to change.

That asymmetry is the whole reason the handle earns its place: it is invisible in a `*T`
signature and now legible in the return type.

### The one place a handle cannot go

`oopz` recognises a struct as a class by finding a **pointer** in its `base` field:

```zig
/// - It is a struct with a `base: *Base` field.
.@"struct" => RecursiveChild(@FieldType(T, "base")),
```

So a class extending a refcounted type cannot write `base: Gd(Resource)` — `isClass` would
return false and `BaseOf` would fail. Teaching `oopz` about handles is a change to a separate
dependency, and not obviously the right one: the base pointer's lifetime is the instance
binding's, which Godot controls, not the caller's.

`release` covers it instead, and now carries a doc comment saying so:

```zig
var base = Resource.init();
self.* = .{ .base = base.release() };
```

Two lines rather than one, for a case with no occurrences in-tree — the repo's only class over
a refcounted field is `RefReturnNode` in `test/leaks`, which now exercises exactly this shape.

### Verification

* `zig build -Dsurface-audit` — every generated declaration analysed, including every `Gd(T)`
  instantiation; no dependency loop from instantiating `Gd(Resource)` inside `resource.zig`.
* `zig build test` — 82/82, including three new assertions in `test/leaks`: that
  `Resource.duplicate()` yields a handle holding exactly one reference (a 2 would prove
  `borrow` was used where `adopt` belonged, a 0 the reverse), that an absent refcounted
  return arrives as `null` rather than a handle to nothing, and that `Resource.init()`'s
  handle owns the initial reference.
* The example runs to a clean self-quit under `--quit-after` with no leaked RIDs and no
  unreferenced-string errors.

---

## Suggested order

1. ~~**3. decide `Gd(T)`**~~ — done; adopted, returns and constructors
2. ~~**1.1 shape reporting**~~ — done; `gdzig-api-audit shapes`
3. ~~**1.2–1.4 shape tests**~~ — done; 85.2% of the method surface
4. ~~**2. indexed properties**~~ — done; 2,920 named accessors

`Gd(T)` went first so that 2 would not have to be revisited, and that paid off exactly as
expected: `StandardMaterial3d.getAlbedoTexture()` forwards to `getTexture(.texture_albedo)` and
returns `?Gd(Texture2d)` with no extra work in the property codegen.

Everything in this plan is now done.
