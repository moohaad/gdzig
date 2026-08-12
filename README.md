# gdzig

Idiomatic Zig bindings for Godot 4.

## DISCLAIMER

This library is currently undergoing rapid development and refactoring as we figure out the best API to expose. Bugs and missing features are
expected until a stable version is released. Issue reports, feature requests, and pull requests are all very welcome.

## Prerequisites

1. zig 0.16.0
2. godot 4.7

**Note:** gdzig targets Godot 4.7 only. Earlier versions are not supported; pin an older gdzig if you need one.

**Note:** We are targeting stable releases of Zig only. 0.15.x is no longer supported; use a tag prior to the 0.16 migration if you need it.

## Usage:

See the [example](example/) folder for reference.

Point the build at a Godot binary:

```sh
zig build -Dgodot-path=/absolute/path/to/godot
```

The path must be absolute. `-Dgodot-path` is currently required: without it the build
downloads Godot itself, and that path is broken on Zig 0.16 — the `godot-versions`
dependency expects `zig fetch` to leave an extracted `p/<hash>/` directory, but 0.16 stores
a `p/<hash>.tar.gz` tarball, so the build fails with "failed to open fetched directory".

## Code Sample:

https://github.com/gdzig/gdzig/blob/1cdfec61d185a9440e6419b122a08e003ad3dcde/example/src/GuiNode.zig#L1-L56

# Community

Find us in the [gdzig Discord server](https://discord.gg/GEUZGRGeDj).
