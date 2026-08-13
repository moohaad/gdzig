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

```sh
zig build
```

That downloads a matching Godot automatically. To build against a specific version or an
engine you already have:

```sh
zig build -Dgodot-version=4.7
zig build -Dgodot-path=/absolute/path/to/godot   # must be absolute
```

## Code Sample:

https://github.com/gdzig/gdzig/blob/1cdfec61d185a9440e6419b122a08e003ad3dcde/example/src/GuiNode.zig#L1-L56

# Community

Find us in the [gdzig Discord server](https://discord.gg/GEUZGRGeDj).
