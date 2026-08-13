# Plan: Godot 4.7 API audit, and dropping pre-4.7 support

Follows `godot-4.7-plan.md`, which got 4.7 building, passing, defaulted, and gated in CI.
Two remaining workstreams, in dependency order:

1. **Drop pre-4.7 support** — deletes machinery the audit would otherwise have to reason about.
2. **Audit the 4.7 surface** — establish what is actually covered, not merely unbroken.

Doing (1) first is deliberate: several audit questions ("is this binding right?") currently
have four answers depending on the running engine, and collapsing that removes the ambiguity
before the measuring starts.

---

## Part 1 — Support Godot 4.7 only

### Already done

- CI matrix is `4.7.1` across Linux, macOS, and Windows; the legacy job is gone.
- `README.md` states 4.7 only, and directs users needing older engines to pin an older gdzig.
- `build.zig` defaults to `latest_version = "4.7"`.
- The `@hasDecl` guard on the global-constants test is gone — on 4.7 the constants always
  exist, and the guard would now hide their absence rather than tolerate it.

### 1.1 Collapse the class-registration ladder — *the substantive one*

`src/extension/class.zig:7-44` picks a different `ClassCreationInfo` per engine version:

```zig
if (gdzig.version.gte(.@"4.4")) {
    ...
} else if (gdzig.version.gte(.@"4.3")) {
    ...
} else if (gdzig.version.gte(.@"4.2")) {
    ...
} else if (gdzig.version.gte(.@"4.1")) {
```

Four branches mapping to Godot's `classdb_register_extension_class` … `_class4`. On 4.7 only
the newest is reachable; the rest are dead weight in the most safety-critical path gdzig has.

Collapse to the 4.4+ branch. Treat this as its own change with its own test run — a mistake
here misregisters every class, and the failure mode is a confusing engine-side error rather
than a compile error.

Check afterwards whether `gdzig.version` still earns its place. If the ladder was its only
real consumer, the runtime version probe in `entrypoint.zig` and `harness.zig` may reduce to a
compatibility assertion: refuse to initialise against an engine older than 4.7 with a clear
message, instead of silently misbehaving.

### 1.2 ~~Adopt `get_godot_version2`~~ — done

The field set does **not** match, contrary to the guess above. `GDExtensionGodotVersion2` is a
superset: it adds `hex`, `status`, `build`, `hash` and `timestamp` ahead of `string`, so the
layout differs at every offset past `patch`.

`gdzig.Version` now mirrors v2 and both entrypoints call `get_godot_version2`. Its absence is
itself the first half of the version check: only an engine older than 4.5 lacks it, which is
already below the supported floor.

Verified on a real 4.6.3 engine, which exercises the changed offsets -- the refusal message
prints the version string correctly, and that field sits at a different offset in v2.

### 1.3 ~~Unconditional feature docs~~ — done

Removed. `is_runtime`, `icon_path` and the indexed-property `index` are unconditionally
available on 4.7, so the minimum-version notes only misled.

### 1.4 ~~Bindgen compatibility branches~~ — investigated, both left as they are

Both turned out to be correct as written; only the comments needed fixing, since each read as
unfinished work.

**Dispatch-table nullability must stay version-based.** Of 179 interface functions, 136 are
`@since 4.1` and non-nullable; the other 43 are nullable. Targeting 4.7 makes all 179
available, so collapsing the distinction looks free -- and is not. `DispatchTable.init`
resolves non-nullable entries with `.?`, and it runs *before* the entrypoint can read the
version. Marking everything required turns "loaded into an engine older than 4.7" from the
clear diagnostic verified in 1.1 into a panic inside `init`, before anything can say why. The
4.1 subset is exactly the set safe to assume while still being able to report the problem.

**The `required` meta carries no information for codegen.** These are two unrelated notions
that share a name: this one is `"meta": "required"` on object arguments, added in 4.6 and
appearing 112 times, marking arguments that must not be null. gdzig already emits every object
argument as a non-optional pointer -- `Area2D.overlaps_body(p_body: *Node)` with the meta is
identical to `Node.is_ancestor_of(p_node: *Node)` without it -- so the annotation adds nothing
the signature does not already enforce.

### 1.5 Retire the multi-version test binary

`tools/godot/godot.exe` (4.6.3) exists only for the cross-version comparisons that found the
4.7 defects. With 4.6 unsupported it stops being a fixture and becomes a stale binary — remove
it and its `.gitignore` entry once Part 2's comparison work is finished, since that work still
wants it.

---

## Part 2 — Audit the 4.7 API surface

### The problem to solve

78 passing tests show that nothing 4.7 changed broke what those tests touch. They say nothing
about coverage. gdzig generates bindings for the entire engine API — thousands of methods —
and exercises a few dozen. The `global_constants` defect is the cautionary case: it sat
undetected not because it was subtle but because *nothing had ever parsed a non-empty
`global_constants`*. Untravelled paths are where these live.

The goal is therefore not "run more tests" but **know which paths have never been walked**.

### 2.1 Keep the differ, make it a tool

The script that found the defect — profile both API dumps, diff per-field value types — is
worth promoting from throwaway to checked-in, under `tools/`.

Two lessons from using it are worth encoding, because both produced wrong answers first:

- **Distinguish list element kinds.** The initial version recorded `list` for any array, so a
  field changing from list-of-string to list-of-object read as identical.
- **Verify which dump you have.** The first comparison was 4.7 against 4.7, because the file
  was chosen with `find | head -1`. The tool should print `header.version_full_name` for both
  inputs before diffing, so the mistake is impossible to repeat silently.

It should also compare *dumps taken with the same flags* — 4.6-with-docs against 4.7-without
shows every `description` field as removed, which is noise.

### 2.2 Measure generated-surface coverage

Mechanical and high value: cross-reference what bindgen generates against what the tests
touch.

- Count generated classes, methods, builtins, enums, flags, constants.
- Extract which of those any test actually calls.
- Report the ratio and, more usefully, the *shape* of the gap: which whole categories are
  untouched.

The output is a prioritised list, not a number. A method never called from Zig is a method
whose marshalling has never been checked, and this session's history — sub-8-byte ptrcall
widths, nullable arg materialization, virtual scalar widths, enum layout — says marshalling
bugs cluster by *category*, not by individual method. Finding an untested category matters
more than an untested method.

### 2.3 Compile-only coverage as the cheap sweep

Full runtime coverage of thousands of methods is not realistic. But *referencing* every
generated declaration is: a generated test that takes the address of every public function and
instantiates every type would catch signature-level breakage — bad types, name collisions,
unresolved imports — across the whole surface at compile time.

The `Signal` shadowing defect would have been caught this way instantly, without a single test
running. It is the highest ratio of defects-caught to effort in this plan.

Note `test/codegen/root.zig` already does this in miniature:

```zig
_ = &ArrayMesh.addSurfaceFromArrays; // "don't execute - needs valid surface data"
```

Generalise that from one hand-picked method to all of them.

### 2.4 Categorise what 4.7 added

With the differ from 2.1, enumerate 4.7's additions against 4.6 — new classes, new methods,
new enum values, changed signatures — and for each ask whether gdzig models it and whether
anything exercises it. `global_constants` was one such addition; the question is what else came
with it that nothing has looked at.

This is the only part requiring the 4.6 binary, hence 1.5's ordering.

### 2.5 Close the gaps worth closing

Output of the above is a ranked list. Expect it to include:

- **Native structures**, already known unhandled (`codegen.zig:1405`, "TODO: native
  structures?"). Parsed into `GodotApi.native_structures`, registered as engine classes, then
  dropped at import resolution.
- **Engine properties**, also known missing (`codegen.zig:435`, "TODO: write properties and
  signals" — signals were done, properties were not).

Both were found by reading, not testing, which is itself a datum: the audit should include a
pass over bindgen's TODOs, since they mark known-unfinished surface.

---

## Suggested order

1. ~~**1.1 registration ladder**~~ — done (`7a9d0fd`). `class.zig` 450 → 286 lines; the
   4.1-4.3 callback wrappers and `PropertyListInstanceBinding` went with it, and the version
   probe now refuses an older engine instead of misregistering. Verified against 4.7.1 and,
   for the refusal path, a real 4.6.3 engine.
2. ~~**2.3 compile-only sweep**~~ — done, and it found a backlog. See "Sweep findings" below.
3. ~~**2.1 differ as a tool** + **2.2 coverage measurement**~~ — done. See "Audit tool" below.
4. **1.2 – 1.4** — mechanical cleanups, no urgency
5. **2.4 / 2.5** — driven by what 2.2 ranks
6. **1.5** — last, once 2.4 no longer needs the 4.6 binary

---

## Sweep findings (2.3)

`src/surface.zig` references every declaration reachable from the public namespaces, forcing
the compiler to analyse each one. Run it with:

```sh
zig build test -Dsurface-audit -Dgodot-path=<godot>
```

It is **opt-in**, because it currently fails. Default builds and CI are unaffected.

### The premise, confirmed

Zig only analyses referenced functions, so building the library proves the generated code
parses, not that it type-checks. Verified directly: a `pub fn` with a deliberate type error,
referenced by nothing, compiles clean under `zig build` and is caught only once something
references it.

Note this revises a claim made earlier in this plan. The `Signal`-shadowing defect would *not*
have needed the sweep — parameter shadowing is a scope error caught at AstGen for any imported
file, which is why a plain `zig build` found it. The sweep's value is the layer below that:
type errors in signatures and bodies that nothing reaches.

### Fixed

**Unary operators passed `null` as a variant type.** `variant_get_ptr_operator_evaluator`
takes the right operand's `GDExtensionVariantType` (a `c_uint`); for a unary operator that is
`NIL`, not a null pointer. bindgen emitted `null`, so every unary operator on every builtin
failed to compile when referenced — 41 errors. Now emits `@intFromEnum(Variant.Tag.nil)`.

**Flag-typed default arguments used the wrong backing width** — 604 errors, now fixed.
Generated as `@bitCast(@as(u64, 3))` for a flag whose representation is `u32`.

`Context.flagRepr` resolved the width from `self.flags` and `self.classes`, falling back to
`"u64"` on a miss. But flag defaults are computed inside `castClasses`, which runs *before*
`castFlags` and populates `self.classes` incrementally. So:

- global flags always missed — `self.flags` was still empty
- qualified class flags (`TextServer.JustificationFlag`) resolved only when the owning class
  sorted alphabetically earlier than the referencing one

which is why `FileAccess.UnixPermissionFlags` resolved from some classes and not others, and
why unqualified own-class references were fine.

Fixed by recording every bitfield's width up front, in `collectFlagRepresentations`, before
any cast pass runs. The rule itself moved to `Flag.representationOf`, which `fromGlobalEnum`
now also calls, so the early pass and the built `Flag` cannot disagree. `flagRepr` reads only
that table and warns on a miss rather than silently assuming `u64`.

Emitted widths went from 909 × `u64` / 38 × `u32` to **932 × `u32` / 15 × `u64`**. The
remaining `u64`s are all `RenderingServer.ArrayFormat`, whose highest bit is 35 — genuinely
64-bit, and generated as `packed struct(u64)`.

**Qualified enum and flag references kept the API's spelling** — 62 errors, now fixed.
`convertQualifiedName` converted the class half of a name and, as its own comment admitted,
appended the "original enum/flag suffix". Declarations use the converted spelling, so any
member whose case actually changes was referenced by a name that does not exist. That is
precisely the ones carrying acronyms: `GeometryInstance3D.GIMode` against the declared
`GiMode`, `Viewport.MSAA` against `Msaa`, `FFTSize`, `GLTFComponentType`, `ASTCFormat`.

Both halves are now converted, taking the member's name from `class.enums` / `class.flags`.
Unlike the flag-width bug this had no ordering hazard: `convertQualifiedName` runs during
codegen, by which point `Context.build` has finished.

**`Variant.Type` referenced a type that is never generated** — 9 errors, now fixed. `Variant`
is hand-written and calls its type tag `Tag`, which is why `castEnums` skips `Variant.*`.
Codegen already hardcoded `Variant.Tag` in the expressions it emits, but type references still
said `Variant.Type`. Redirected through a small `renamed_qualified_enums` table, which also
documents why the rename exists.

### Cleared

The rest fell into five more causes:

**Non-empty `String` / `StringName` / `NodePath` defaults were discarded.** Only the empty
cases were special-cased; anything else fell through to `parse`, producing a nullable value
that materialized as `.init()`. `NodePath("")` additionally became `NodePath.copy("")`, and
`copy` takes a NodePath.

This one is worth dwelling on: for `String` it was **silent**. `FileAccess.get_csv_line(delim:
String = ",")` compiled fine and defaulted to `""` instead of `","`; likewise
`bind_address = "*"` on four networking methods. The compiler could never have caught it —
found only by reading the API alongside the generated output while chasing the StringName
error next to it.

Defaults that cannot be a comptime field initializer now go through
`Parameter.default_materializer`, which supplies the expression that reconstitutes the
argument. `Variant = 0` (`RegExMatch.get_string`) uses the same route.

**`Variant` methods taking `self: *Variant` passed `&self`.** Six of them — `call`, `set`,
`setNamed`, `setKeyed`, `setIndexed`, `ptr` — took a pointer receiver and then took its
address again, handing the engine a `**Variant`: the address of the parameter slot rather than
the value. The neighbouring methods take `self: Variant` by value, where `&self` is right,
which is presumably how it went unnoticed. Nothing referenced any of the six, so nothing ever
compiled them.

**`variantGetObjectInstanceId` was called without unwrapping** the optional dispatch pointer.
Same shape as the earlier `String.fromUtf8/16` fix.

**`Variant.Tag.forType(Variant)` hit a `@compileError`.** The generated `eqlVariant` /
`notEqlVariant` operators ask for the tag of a `Variant` right-hand side. A dynamically typed
operand has no static tag; the engine spells that NIL, which is what godot-cpp passes too.

**`Rect2.initXYWidthHeight` took `i64`** and forwarded to `Vector2.initXY`, which takes `f64`.
Hand-written in the mixin.

**`Plane`'s constants called a runtime constructor.** `plane_yz` and friends were
`initABCD(1, 0, 0, 0)`, but `initABCD` goes through the engine's constructor table and cannot
be evaluated at comptime. Rewritten in the mixin over `initNormalD` and `Vector3.initXYZ`,
which assign fields directly. Mixin constants override the API-derived ones, since both key on
the same screaming-case name.

**`vtable.zig` exceeded its eval branch quota.** Not a defect. `combineNames` computes its own
return type by calling `countNew`, which is evaluated before that function's body and so
before any quota it sets; the budget is shared across the comptime call tree. Raised at
`extend`, the outermost entry.

### Turning it on

**The backlog is clear: 0 errors.** Progress was 735 on first run, then 694 (unary
operators), 90 (flag widths), 29 (qualified enum names), 20 (`Variant.Type`), 14 (string and
path defaults), 7 (`Variant` self-pointers), 0.

CI runs the sweep as its own step, so a surface regression is distinguishable from a test
failure. It stays off by default rather than becoming part of every local `zig build test`.

That split is a judgement call made without a measurement. Attempts to time the delta all
returned cache hits -- Zig reuses both the compile and the Run step results, and neither
touching a file nor appending a comment reliably forced the unit-test step to rebuild. Rather
than quote a meaningless number, the conservative option was taken. Anyone who gets a real
cold-cache measurement should revisit it: if the cost is small, this belongs on by default.

Measure build cost before flipping it — referencing the whole API is a large compilation unit,
and if it is slow it belongs in its own CI job rather than in every local `zig build test`.

---

## Audit tool (2.1 + 2.2)

`zig build audit` builds `gdzig-api-audit`, which reads the API dump dynamically rather than
through `GodotApi` -- deliberately, since a typed parse can only see fields the model already
knows about, and the interesting changes are the ones it does not.

### `diff <old.json> <new.json>`

Profiles the shape of both dumps and reports where they disagree. Run against 4.6.3 and 4.7 it
independently reproduces the finding that took several wrong turns by hand:

```
old: Godot Engine v4.6.3.stable.official  (with docs)
new: Godot Engine v4.7.stable.official  (with docs)

global_constants.description:  old = <absent>  new = string
global_constants.is_bitfield:  old = <absent>  new = bool
global_constants.name:         old = <absent>  new = string
global_constants.value:        old = <absent>  new = number
```

Both guards from the plan are implemented and refuse with an explanation rather than a
misleading empty result: comparing a dump against itself, and comparing dumps taken with
different `--dump-extension-api-with-docs` settings. Array kinds carry their element type, so
a field that changes from list-of-string to list-of-object is not reported as unchanged.

### `coverage <extension_api.json> <test-dir>...`

Against 4.7 and `test/`:

| category | touched | total | percent |
| --- | ---: | ---: | ---: |
| classes | 7 | 1036 | 0.7% |
| class methods | 24 | 11300 | 0.2% |
| builtins | 5 | 38 | 13.2% |
| builtin methods | 13 | 421 | 3.1% |
| utility functions | 3 | 114 | 2.6% |

The sweep proves all 11300 class methods *type-check*; this says 24 of them have ever *run*.
Both numbers are worth having, and the gap between them is the point: marshalling bugs only
appear when a call actually crosses the FFI boundary, and that is where every such bug in this
codebase has been found.

Matching is textual and the rule differs by category, which matters when reading the numbers:

- **Types** count when the name appears as a standalone identifier. Requiring a call would
  report nearly every type as untouched, because Zig's decl literals mean a type is usually
  named only in the annotation -- `var a: Array = .init()` never writes `Array.init`. This
  also counts an unused import, so type figures are an upper bound.
- **Methods** count only when followed by `(`. Exact, except that two same-named methods on
  different types are indistinguishable.

`Variant` is absent from the builtin list because the API does not classify it as a builtin
class; it is handled specially by hand-written code.

## Risks

**The ladder collapse is the one that can break everything.** Class registration is on the path
for every extension. Failures surface engine-side, not as compile errors. Its own commit, its
own full run, and ideally a manual example launch as well as `zig build test`.

**Dropping pre-4.7 is user-visible and not reversible by them.** Anyone on 4.4 – 4.6 must pin an
older gdzig. Given `0.0.0-dev` and a README that already warns of rapid change, that is
defensible, but a CHANGELOG entry naming the last 4.6-capable commit would cost little.

**A compile-only sweep can regress build times.** Referencing every declaration in the API is a
large compilation unit. Measure before and after; if it is slow, make it its own test folder
that CI runs rather than something every local `zig build test` pays for.
