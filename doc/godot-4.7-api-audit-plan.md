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

### 1.2 Adopt `get_godot_version2`

`src/DispatchTable.zig:6` documents `get_godot_version` as "Deprecated in Godot 4.5. Use
`get_godot_version2` instead", and line 1849 still binds the deprecated one. On a 4.7-only
target there is no reason to keep the old entry point.

Low risk, but it touches the version struct layout — confirm the field set matches.

### 1.3 Unconditional feature docs

`Registry.zig` annotates options with minimum versions: `is_runtime` "Requires Godot 4.3+",
`icon_path` "Requires Godot 4.4+", indexed properties "Requires Godot 4.2+". All are
unconditionally available on 4.7; the notes now mislead more than they inform. Delete them, or
restate as history if the provenance is worth keeping.

### 1.4 Bindgen compatibility branches

Two known spots:

- `codegen.zig:1554` — "required (4.1) functions are non-nullable, optional (4.2+) are
  nullable" in the dispatch-table writer.
- `Function.zig:99` — `"required"`, "Introduced in 4.6. ignore for now".

The second is the interesting one: 4.7 emits a `required` field that bindgen discards. Decide
whether it should inform nullability instead of being ignored — potentially replacing the
version-based rule at `codegen.zig:1554` with the engine's own declaration.

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
3. **2.1 differ as a tool** + **2.2 coverage measurement** — turns "unknown" into a ranked list
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

### Outstanding — 90 errors

Remaining, unanalysed:

| Count | Error |
| --- | --- |
| 62 | `opaque X has no member named Y` |
| 8 | `struct X has no member named Y` |
| 7 | `expected type X, found Y` |
| 6 | `@ptrCast discards const qualifier` |
| 2 | `unable to resolve comptime value` |
| 2 | `evaluation exceeded 20000 backwards branches` |

The last is a generated `@setEvalBranchQuota(20000)` that is simply too low under the sweep,
not a defect.

### Turning it on

The sweep should gate CI once the backlog clears; until then it is a worklist. The flag-width
pass is done, taking it from 694 to 90. What is left is triage of the 90, then flipping the
default and dropping the option.

Measure build cost before flipping it — referencing the whole API is a large compilation unit,
and if it is slow it belongs in its own CI job rather than in every local `zig build test`.

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
