# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

### Build Commands
The build defines exactly four steps; run `zig build -h` to confirm.
- `zig build` - Build the library and bindgen, run bindgen, and install the generated
  bindings (to `src/`), the bindgen executable, the docs (to `zig-out/docs`), and the
  Godot headers (to `zig-out/vendor`)
- `zig build check` - Check the build without installing artifacts
- `zig build test` - Run unit tests plus the Godot integration tests under `test/`
- `zig build test -Dsurface-audit` - Additionally type-check every generated declaration.
  Zig only analyses referenced functions, so the plain build proves the bindings parse, not
  that they compile; CI runs this as its own step
- `zig build audit` - Build `gdzig-api-audit`, which diffs two `extension_api.json` dumps
  (`diff old.json new.json`) or reports how much of the generated surface the tests exercise
  (`coverage extension_api.json test`)
- `zig build uninstall` - Remove installed artifacts

### Build Options
- `-Dgodot-path=<path>` - Path to a Godot executable
- `-Dgodot-version=<version>` - Download and use this Godot version (e.g. `latest` or `4.7`)
- `-Dprecision=<float|double>` - Floating point precision (default: "float")
- `-Darch=<32|64>` - Architecture bits (default: "64")
- `-Dtarget=<target>` - Cross-compilation target
- `-Doptimize=<Debug|ReleaseSafe|ReleaseFast|ReleaseSmall>` - Optimization mode

Prefer `-Dgodot-path` while the `godot-versions` dependency's `FetchStep` remains broken on
Zig 0.16 (it expects `zig fetch` to leave an extracted `p/<hash>/` directory, but 0.16 stores
a `p/<hash>.tar.gz` tarball). Without it, any build that has to download Godot fails with
"failed to open fetched directory".

### Example Project Commands (from example/ directory)
- `zig build run` - Build example and run with Godot
- `zig build load` - Load the example project in Godot editor

### Documentation Commands
- `zigdoc <symbol>` - Show documentation for Zig standard library symbols and imported modules
  - Examples:
    - `zigdoc std.ArrayList` - Show ArrayList documentation
    - `zigdoc std.zig.Ast` - Show AST documentation
    - `zigdoc std.zig.Ast.parse` - Show documentation for specific function
  - Can access any module imported in build.zig, including third-party dependencies
  - Use `zigdoc --dump-imports` to see available modules

## Architecture

### Core Components

**gdzig_bindgen/** - Code generator that parses Godot's extension_api.json and generates Zig bindings
- `Context.zig` - Central context that builds the codegen model from Godot API
- `GodotApi.zig` - Parser for extension_api.json
- `codegen.zig` - Main code generation logic that writes out all binding files
- `CodeWriter.zig` - Utility for writing formatted Zig code with proper indentation
- `Context/*.zig` - Type definitions for Godot concepts (Class, Function, Signal, Property, etc.)

**gdzig/** - Runtime library and generated bindings
- `gdzig.zig` - Main entry point exposing all public APIs
- `builtin/*.zig` - Generated bindings for Godot builtin types (Vector2/3, String, Array, etc.)
- `class/*.zig` - Generated bindings for Godot classes (Node, Object, RefCounted, etc.)
- `global/*.zig` - Generated global enums and constants
- Core runtime modules:
  - `interface.zig` - Static interface to GDExtension C API functions
  - `heap.zig` - Integration with Godot's memory allocator
  - `object.zig` - Object lifecycle and inheritance support
  - `register.zig` - Class, method, and signal registration
  - `string.zig` - String conversion utilities
  - `support.zig` - Method binding and constructor utilities
  - `meta.zig` - Type introspection and class hierarchy

### Code Generation Flow

1. **Parse Phase**: `GodotApi.parseFromReader()` reads extension_api.json
2. **Context Build**: `Context.build()` transforms raw API into codegen model:
   - Builds symbol lookup tables
   - Parses GDExtension headers
   - Collects class hierarchies and dependencies
   - Resolves type mappings for current architecture/precision
3. **Generation Phase**: `codegen.generate()` writes binding files:
   - `writeBuiltins()` - Core value types
   - `writeClasses()` - Class hierarchy
   - `writeGlobals()` - Enums and constants
   - `writeInterface()` - C API function pointers
   - `writeModules()` - Utility function modules
4. **Format**: Auto-formats generated code with `zig fmt`

### Type System

- Uses Zig 0.16 features, including the `std.Io` interface (`std.Io.Dir`/`std.Io.File`/`Reader`/`Writer`)
- Builtin types map to Zig equivalents based on precision setting (float/double)
- Classes use oopz dependency for OOP-style inheritance
- Supports both 32-bit and 64-bit architectures
- Automatic type conversions between Zig and Godot types

### Extension Entry Point

Extensions define an entry point using `gdzig.entrypoint()` or `gdzig.entrypointWithUserdata()`:
- Specify initialization/deinitialization callbacks per level (core, servers, scene, editor)
- Register custom classes, methods, properties, and signals
- Handle object lifecycle through Godot's reference counting

## Dependencies

- **case** - Case conversion utilities
- **bbcodez** - BBCode parsing for documentation
- **temp** - Temporary file utilities
- **oopz** - OOP abstractions for Zig
- **godot_cpp** - Optional source for Godot headers

## Current Status

- Migrated to Zig 0.16. File I/O goes through `std.Io`, so an `Io` instance must be threaded
  to every file/dir/process call. In bindgen it is carried on `Config.io` (reach it via
  `ctx.config.io`); in the test coordinator it comes from `std.process.Init`; the test harness
  builds its own `std.Io.Threaded` because, as a shared library, it has no `main`.
- Main branch for PRs: `master`
- To see the generated code: run `zig build`. The generated code is installed into the `src/` folder.
