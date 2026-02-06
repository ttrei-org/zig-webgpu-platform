# AGENTS.md

## Project-specific instructions

Take screenshots during development to verify the output is correct:
```bash
# Native desktop screenshot
xvfb-run zig build run -- --screenshot=/tmp/screenshot.png

# Web screenshot (uses xvfb + Firefox internally)
./scripts/web_screenshot.sh /tmp/web_screenshot.png
```

---

## Browser Testing with Playwright

### Web Screenshots

The project includes a script for capturing web screenshots using Playwright with Firefox and xvfb. It handles everything internally (virtual display, browser config, web server lifecycle):
```bash
./scripts/web_screenshot.sh /tmp/web_screenshot.png
```

An optional second argument controls the wait time (seconds) before capturing, to allow WebGPU initialization:
```bash
./scripts/web_screenshot.sh /tmp/web_screenshot.png 8
```

**Key points:**
- The script uses Firefox with `dom.webgpu.enabled` set via `firefoxUserPrefs`, so it works without GPU hardware
- `xvfb-run` is invoked internally — no need to wrap the script with it
- The web server (`serve.py`) is started and stopped automatically
- Uses `playwright-cli run-code` with `page.screenshot()` to save to a file path

---

## Integration Testing

### Testing scaffolded projects locally

To test the create-app scaffolding tool end-to-end:
```bash
# Build the create-app tool
zig build  # in create-app/ directory

# Scaffold a test project (fetches templates from GitHub, resolves dependency)
create-app/zig-out/bin/zig-webgpu-create-app /tmp/test-project

# Verify the scaffolded project builds
zig build                              # in /tmp/test-project
zig build -Dtarget=wasm32-emscripten   # in /tmp/test-project
```

### Playwright session caching

If web screenshots show stale content, delete the Playwright session cache before retaking:
```bash
playwright-cli session-delete
```

---

## Zig Development

Always use `zigdoc` to discover APIs for the Zig standard library and any third-party dependencies.

Examples:
```bash
zigdoc std.fs
zigdoc std.posix.getuid
zigdoc ghostty-vt.Terminal
zigdoc vaxis.Window
```

## Common Zig Patterns

These patterns reflect current Zig APIs and may differ from older documentation.

**ArrayList:**
```zig
var list: std.ArrayList(u32) = .empty;
defer list.deinit(allocator);
try list.append(allocator, 42);
```

**HashMap/StringHashMap (unmanaged):**
```zig
var map: std.StringHashMapUnmanaged(u32) = .empty;
defer map.deinit(allocator);
try map.put(allocator, "key", 42);
```

**HashMap/StringHashMap (managed):**
```zig
var map: std.StringHashMap(u32) = std.StringHashMap(u32).init(allocator);
defer map.deinit();
try map.put("key", 42);
```

**stdout/stderr Writer:**
```zig
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
defer writer.interface.flush() catch {};
try writer.interface.print("hello {s}\n", .{"world"});
```

**build.zig executable/test:**
```zig
b.addExecutable(.{
    .name = "foo",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

## Zig Code Style

**Naming:**
- `camelCase` for functions and methods
- `snake_case` for variables and parameters
- `PascalCase` for types, structs, and enums
- `SCREAMING_SNAKE_CASE` for constants

**Struct initialization:** Prefer explicit type annotation with anonymous literals:
```zig
const foo: Type = .{ .field = value };  // Good
const foo = Type{ .field = value };     // Avoid
```

**File structure:**
1. `//!` doc comment describing the module
2. `const Self = @This();` (for self-referential types)
3. Imports: `std` → `builtin` → project modules
4. `const log = std.log.scoped(.module_name);`

**Functions:** Order methods as `init` → `deinit` → public API → private helpers

**Memory:** Pass allocators explicitly, use `errdefer` for cleanup on error

**Documentation:** Use `///` for public API, `//` for implementation notes. Always explain *why*, not just *what*.

**Tests:** Inline in the same file, register in src/main.zig test block

## Safety Conventions

Inspired by [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md).

**Assertions:**
- Add assertions that catch real bugs, not trivially true statements
- Focus on API boundaries and state transitions where invariants matter
- Good: bounds checks, null checks before dereference, state machine transitions
- Avoid: asserting something immediately after setting it, checking internal function arguments

**Function size:**
- Soft limit of 70 lines per function
- Centralize control flow (switch/if) in parent functions
- Push pure computation to helper functions

**Comments:**
- Explain *why* the code exists, not *what* it does
- Document non-obvious thresholds, timing values, protocol details

<!-- br-agent-instructions-v1 -->

---

## Beads Workflow Integration

This project uses [beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`/`bd`) for issue tracking. Issues are stored in `.beads/` and tracked in git.

### Essential Commands

```bash
# View ready issues (unblocked, not deferred)
br ready              # or: bd ready

# List and search
br list --status=open # All open issues
br show <id>          # Full issue details with dependencies
br search "keyword"   # Full-text search

# Create and update
br create --title="..." --description="..." --type=task --priority=2
br update <id> --status=in_progress
br close <id> --reason="Completed"
br close <id1> <id2>  # Close multiple issues at once

# Sync with git
br sync --flush-only  # Export DB to JSONL
br sync --status      # Check sync status
```

### Workflow Pattern

1. **Start**: Run `br ready` to find actionable work
2. **Claim**: Use `br update <id> --status=in_progress`
3. **Work**: Implement the task
4. **Complete**: Use `br close <id>`
5. **Sync**: Always run `br sync --flush-only` at session end

### Key Concepts

- **Dependencies**: Issues can block other issues. `br ready` shows only unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers 0-4, not words)
- **Types**: task, bug, feature, epic, chore, docs, question
- **Blocking**: `br dep add <issue> <depends-on>` to add dependencies

### Session Protocol

**Before ending any session, run this checklist:**

```bash
git status              # Check what changed
git add <files>         # Stage code changes
br sync --flush-only    # Export beads changes to JSONL
git commit -m "..."     # Commit everything
git push                # Push to remote (only if there is a remote defined)
```

### Best Practices

- Check `br ready` at session start to find available work
- Update status as you work (in_progress → closed)
- Create new issues with `br create` when you discover tasks
- Use descriptive titles and set appropriate priority/type
- Always sync before ending session

<!-- end-br-agent-instructions -->
