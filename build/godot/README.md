# Vendored: godot-versions

Downloads a Godot binary of a requested version and dumps `extension_api.json`
and `gdextension_interface.h` from it. Used by the root `build.zig` to resolve
`-Dgodot-version`.

Vendored from [gdzig/godot-versions](https://github.com/gdzig/godot-versions)
at commit `cb41d4a`, rather than consumed as a package dependency.

## Why vendored

Zig resolves `build.zig.zon` dependencies by URL and hash, so a fix has to be
reachable at a URL before anything can use it. Two Zig 0.16 breakages in this
code left `-Dgodot-version` non-functional, and vendoring made those fixable
here instead of blocking on an upstream release.

## Local changes

Both are Zig 0.16 breakages, not gdzig-specific behaviour. If they are ever
fixed upstream, this directory can go back to being a dependency.

**`FetchStep.zig` — unpack the fetched tarball.** `zig fetch` no longer leaves
an extracted directory at `p/<hash>`; it stores `p/<hash>.tar.gz` and offers no
flag to extract. The step previously failed with "failed to open fetched
directory" before it could copy anything out, and now unpacks the tarball
itself. The recursive `copyEntry` helper that replaced had no other callers and
was removed.

**`HeadersStep.zig` — anchor the Godot path.** The dump runs with its cwd set to
the output directory, so the executable path has to be absolute.
`std.fs.path.resolve` was relied on for that, but in 0.16 it is purely lexical —
no syscalls, never consults the process cwd — so a single relative path comes
back unchanged and the child cannot find an executable named relative to a
directory it is no longer in. Now anchored with `Build.pathFromRoot`. The spawn
failure also reports both paths; it previously surfaced as a bare
`error: FileNotFound`.

## Updating

`versions.zon` is generated, not hand-edited. `sync.sh` regenerates it from the
`godot-builds` releases; re-run it to pick up new Godot versions, or copy a
fresher `versions.zon` from upstream.
