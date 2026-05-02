# oxwm — agent instructions

## Build & dev

| Command | What |
|---|---|
| `zig build` | Build (min Zig 0.15.2, see `build.zig.zon`) |
| `zig build test` | Run all 3 test suites |
| `zig build xephyr` | Launch in Xephyr 1280x800 on `:2` w/ `resources/test-config.lua` |
| `zig build kill` | `pkill -9 Xephyr` + `pkill -9 oxwm` |
| `zig build fmt` | `zig fmt src/` only |
| `zig build clean` | Remove `zig-out/` and `.zig-cache/` |
| `zig build run` | Run the built binary |
| `nix develop` | Nix dev shell (zig, zls, zon2nix, alacritty, xorg-server) |

Runtime flags: `oxwm --init` (create default config), `oxwm --validate` (validate config without starting WM), `oxwm --config <path>`, `oxwm --version`.

## Project facts

- **Pure Zig** — `resources/PKGBUILD` mentions Cargo/Rust but is a stale artifact; no Rust code remains.
- **Config is Lua** (`~/.config/oxwm/config.lua`), hot-reloaded with `Mod+Shift+R`.
- **No CI/CD** — no GitHub Actions, no pre-commit hooks, no Makefile.
- **`.gitignore` ignores `*.md`** — `AGENTS.md` must be force-added (`git add -f AGENTS.md`) or `.gitignore` amended with `!AGENTS.md`.

## Architecture

```
src/
├── main.zig           Entry point, CLI arg parsing
├── wm/                WindowManager core, event dispatch, actions
├── config/            Config struct + Lua bridge (1531 lines)
├── bar/               Status bar + modular blocks (battery, datetime, ram, etc.)
├── layouts/           Tiling, monocle, floating, grid, scrolling
├── x11/               Xlib/Xft/Xinerama Zig bindings
├── client.zig         Window client management
├── monitor.zig        Multi-monitor (RandR/Xinerama)
├── overlay.zig        Keybind overlay
└── animations.zig     Scroll animations
```

Tests in `tests/`: `main_tests.zig` (imports `config_tests.zig`), `lua_config_tests.zig` (loads `resources/test-config.lua`).

## Keybinds

Default mod is Mod4 (Super). See `templates/config.lua` or `readme.org` for full table. Hot reload: `Mod+Shift+R`.
