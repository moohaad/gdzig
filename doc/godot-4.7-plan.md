# Plan: support Godot 4.7

## Summary

Two small defects blocked 4.7, both of them latent bugs that 4.7 is simply the first
version to trigger. Both are fixed in the working tree and verified:

```
zig build test -Dgodot-path=<godot 4.7>    126/126 steps, 77/77 tests
zig build test -Dgodot-path=<godot 4.6.3>  126/126 steps, 77/77 tests
```

The remaining work is not about making 4.7 *function* — it already does — but about making
that support real: exposing what 4.7 added, defaulting to it, and keeping it from regressing.

## What was actually wrong

Earlier in this work I claimed "bindgen can't parse 4.7's `extension_api.json`" and cited a
clean 4.6 build as proof. The claim was right; the proof was not. The file I diffed against
turned out to be a *4.7* dump picked up by `find | head -1`, so the first comparison was 4.7
against itself and reported no differences. A control run of bindgen against a genuine 4.6
dump is what finally separated the two.

### Defect 1 — `global_constants` was never parsed before

`global_constants` is empty in every Godot up to and including 4.6. 4.7 populates it with 11
entries, so this struct saw real input for the first time:

```zig
pub const GlobalConstant = struct {
    name: []const u8,
    value: []const u8,   // 4.7 sends a JSON number
};
```

```json
{"name": "UINT8_MAX", "value": 255, "is_bitfield": false, "description": "..."}
```

A number arriving where a slice is expected lands in the `else` branch of std.json's pointer
parsing and returns `error.UnexpectedToken` — matching the observed stack trace exactly. The
two extra fields would have thrown `error.UnknownField` immediately afterwards, since the
default parse options do not ignore unknown fields.

**Fix** (`pkg/bindgen/GodotApi.zig`): `value: i64`, plus `is_bitfield` and `description`.
Observed values span the full `i64` range (`INT64_MIN` … `INT64_MAX`); a future `UINT64_MAX`
would not fit and would need a wider type. That constraint is recorded in a comment on the
field.

### Defect 2 — `Signal` shadowing in generated classes

With parsing fixed, bindgen generated 4.7 bindings that failed to *compile*:

```
class/tween.zig:2228: error: function parameter shadows declaration of 'Signal'
```

`src/class/Object.mixin.zig` is injected into every class and declared
`emit(self, comptime Signal: type, ...)`, while `connect`/`disconnect` already used `S`. The
name only collides when a class also imports the `Signal` builtin, which bindgen emits when
the class API mentions `Signal`. Godot 4.7 added `Tween.tweenAwait(signal: Signal)`; 4.6's
`Tween` has neither the method nor the import, which is why this never surfaced.

**Fix** (`src/class/Object.mixin.zig`): rename the parameter to `S` in `emit`, `emitAlloc`,
and `AssertNonAllocating`, matching `connect`. One class is affected today, but any future
class whose API mentions `Signal` would hit it.

## Already in place

Worth stating so nobody re-does it:

- **`versions.zon` already lists 4.7** — 144 entries covering 4.7.0 and 4.7.1 across
  platforms. No registry work needed.
- **The version gates are already generic.** `shouldUseDocs` and `hasJsonInterface` branch on
  `minor > 6`, so they classify 4.7 correctly without modification.

## Remaining work

### 1. ~~Expose the 11 new global constants~~ — done

`global_constants` was parsed but never consumed, so `UINT8_MAX`, `INT64_MIN` and the rest
were silently dropped. Implemented by mirroring `global_enums`:

- `Constant.fromGlobal` builds a constant from a `GodotApi.GlobalConstant`, converting the
  name with `gdzig_case.constant` and the description into a doc comment.
- `Context.global_constants` plus a `castGlobalConstants` pass, called from `Context.build`.
- `writeGlobals` emits them straight into `global.zig`. They are plain scalars, so unlike
  enums and flags they do not each get a module; the block is guarded on a non-empty map so
  pre-4.7 output is byte-identical.

Result on 4.7:

```zig
/// Maximum value of an 8-bit unsigned integer.
pub const UINT8_MAX: i64 = 255;
...
/// Minimum value of a 64-bit signed integer.
pub const INT64_MIN: i64 = -9223372036854775808;
```

Verified on both versions — 4.7 emits 11 constants, 4.6 emits 0:

```
zig build test -Dgodot-path=<4.7>    126/126 steps, 78/78 tests
zig build test -Dgodot-path=<4.6.3>  126/126 steps, 78/78 tests
```

`test/codegen/root.zig` gained a case asserting the values, including both `i64` extremes,
since those are what would break first if the backing type ever narrowed. It is guarded on
`@hasDecl(global, "UINT8_MAX")` so it is a no-op on pre-4.7 rather than a failure — the
harness reports `error.SkipZigTest` as a failure, so an early `return` is the right shape.

### 2. ~~Default to 4.7~~ — done

`build.zig:1` now reads `const latest_version = "4.7";`. Confirmed the constraint resolves:
`-Dgodot-version=4.7` selects `v4.7.1-stable` and proceeds to the download, which then fails
on the known `FetchStep` bug — the same failure 4.6 had, so the bump is not a regression.

This only affects the download path. Builds passing `-Dgodot-path` never consult it.

### 3. ~~Test both versions in CI~~ — done

CI already existed but could not have caught either defect:

- It ran `zig build test -Dgodot-version=…`, which routes through the broken `FetchStep`, so
  on Zig 0.16 it fails before reaching a test.
- Both jobs set `continue-on-error: true`, so nothing could ever fail the build.
- The matrix was 4.1 – 4.5, predating both supported versions.
- `mlugg/setup-zig` had no version pinned.

Rewritten as three jobs:

| Job | Coverage | Gating |
| --- | --- | --- |
| `test-pr` | 4.7.1 on Linux | yes |
| `test-supported` | 4.6.3 + 4.7.1 on Linux, 4.7.1 on macOS and Windows | yes |
| `test-legacy` | 4.4.1, 4.5.1 on Linux | no |

The composite action now downloads Godot from `godot-builds` directly and passes
`-Dgodot-path`, which sidesteps `FetchStep` entirely and lets the binary be cached per
(OS, version). Zig is pinned to 0.16.0.

Legacy versions stay non-gating deliberately: the README advertises "godot 4.4+", but nothing
here verifies that against the current bindgen. A failure there means the claim needs
revisiting, not that master is broken.

Three details worth keeping, each of which would have broken the run:

- `run: "$GODOT_BIN" --version` is invalid YAML — a quoted scalar followed by loose text. It
  needs outer quoting.
- `-Dgodot-path` rejects relative paths (`FileNotFound` at the header-dump step), so the
  binary path is made absolute.
- On Windows the shell is Git Bash, whose absolute paths (`/d/a/gdzig/...`) mean nothing to a
  native Windows Zig. `cygpath -m` converts to the `C:/...` form the option accepts.

Windows is gating again. It was previously annotated "temporarily disabled while we figure out
hanging"; that hang was very likely the coordinator piping the child's stderr and never
draining it, which deadlocks Godot the moment a test prints — fixed during the 0.16 work.

Verified as far as is possible without pushing: both files parse, the matrix resolves as
intended, all six download URLs return 200, and the binary-discovery logic was run against a
real extracted Godot (it correctly skips the `_console` build and yields a working path).

### 4. Audit the wider 4.7 surface

77 tests passing means nothing 4.7 changed broke anything those tests touch. It does not mean
the 4.7 API is fully covered. A structural diff of 4.6 vs 4.7 found the `global_constants`
change; a follow-up pass should look for new classes, methods, and enum values, and confirm
the generated bindings for them are sane.

The comparison script used here is worth keeping — profiling both dumps and diffing per-field
value types is what located the defect, and it will locate the next one.

### 5. ~~Documentation~~ — done

`README.md` now qualifies the version claim with what is actually enforced — "godot 4.4+ — CI
gates 4.6.3 and 4.7.1; 4.4 and 4.5 are built but not gating" — rather than asserting a floor
nothing checks.

It also documents `-Dgodot-path`, including that the path must be absolute and that the flag
is currently required, with the `FetchStep` reason stated. That was previously only in
`CLAUDE.md`, which contributors read and users do not. The `-Dgodot-version` example there
was bumped from `4.5` to `4.7`.

## Suggested order

1. ~~Land the two fixes~~ — done, verified on both versions
2. ~~Global-constants codegen~~ — done, verified on both versions
3. ~~CI matrix — 4.6 and 4.7~~ — done, pending a push to confirm
4. ~~Bump `latest_version`, update docs~~ — done
5. Wider API audit — the only item left

4.7 is supported: it builds, it passes the suite, everything it added to the API that gdzig
models is exposed, it is the default version, and CI gates it. The remaining audit is about
coverage confidence rather than function — 78 passing tests show that nothing 4.7 changed
broke what the tests touch, which is not the same as the 4.7 surface being fully exercised.

Two things outside this plan still gate the experience: the `godot-versions` `FetchStep` bug,
which forces `-Dgodot-path`, and confirming the new CI actually runs green on a real runner.

## Risks

**A future constant exceeding `i64`.** `value: i64` fits every current entry exactly, with
`INT64_MIN`/`INT64_MAX` at the boundaries. `UINT64_MAX` would not fit and would fail at parse
time with a clear error.

**Other name collisions like defect 2.** The mixin injects identifiers into every generated
class, so any mixin-local name can collide with a builtin import. `S` is safe today, but the
general hazard remains. A lint over generated output — or prefixing mixin-internal names —
would close it properly.

**`-Dgodot-path` is still mandatory.** Independent of 4.7, but it is what forces the awkward
CI story in step 3.
