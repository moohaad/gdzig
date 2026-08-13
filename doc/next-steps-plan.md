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

Current state: **16 of 784 shapes exercised, 3,712 of 16,822 methods (22.1%)**, with 15 more
shapes (25.5%) reached only ambiguously. The largest uncovered shapes are
`object/builtin <- ()` (1,409 methods) and `void <- (object/builtin)` (1,400).

**1.2 Cover the top shapes.** Work down the ranked list, one test per shape, picking whichever
real method exercises it most cheaply. Round-trip where possible — set a value, read it back,
assert equality — since that catches marshalling in both directions, which is how the
sub-8-byte ptrcall bug manifested.

Stop at a stated threshold. 50 shapes for 85% is a reasonable first target; the next 50 buy
under 6% and cost the same.

**1.3 Poison the stack.** `test/codegen/root.zig` already has `poisonStack()`, written for
exactly the bug class where a narrow return leaves adjacent bytes intact and the test passes by
luck. Shape tests for scalar and enum returns should use it, or they will not catch a
recurrence.

**1.4 Report the number.** Once shapes are tracked, the coverage report should lead with shape
coverage rather than method coverage. "24 of 11,300 methods" is technically true and useless;
"38 of 459 shapes, covering 71% of methods" is actionable.

### Risk

Shape equivalence is an assumption, not a proof. Two methods sharing a shape share a
marshalling path *as currently generated*; a future codegen change could special-case one and
not the other. The mitigation is that 1.1 recomputes shapes from the API each run, so the
worklist tracks reality rather than a snapshot.

---

## 2. Indexed properties

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

### Steps

**2.1 Write `writeClassProperty`.** For each indexed property with a non-numeric name, emit a
getter, and a setter when one exists, that supply the index:

```zig
pub fn getAreaRange(self: *const AreaLight3d) f64 {
    return self.getParam(@enumFromInt(4));
}
```

Prefer the enum member over the bare integer where the accessor's index parameter is an enum
type — that is the entire point of the exercise, and `Context.Property` already carries
`index`, `getter` and `setter`.

**2.2 Skip the numeric-suffix cases**, and say so in a comment so the omission reads as a
decision rather than an oversight.

**2.3 Enable the loop** at `codegen.zig`, whose commented-out body is already written against
this function.

**2.4 Test one of each.** A round-trip on a named indexed property, plus one on a shared
accessor like `BaseMaterial3D`, is enough — this is codegen, so the cases are uniform.

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
3. **1.2–1.4 shape tests** — the highest-value engineering here, and now a ranked worklist
4. **2. indexed properties** — bounded, and the design questions are already answered

`Gd(T)` went first so that 2 would not have to be revisited: an indexed getter forwards to its
accessor, so one whose accessor returns a refcounted class now returns `?Gd(T)` for free.
