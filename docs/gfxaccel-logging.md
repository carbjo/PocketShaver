# gfxaccel logging

All graphics-acceleration subsystems (GL, RAVE, DSp, NQD, compositor) log through
`os_log`. Logging is **off by default** in a clean checkout and is toggled with
`tools/gfxlog.sh`.

## Two layers

1. **Compile flag** `ACCEL_LOGGING_ENABLED` (in `SheepShaver/src/gfxaccel/include/accel_logging.h`).
   - `0` (ship default): every `*_LOG`/`*_VLOG` macro compiles to a no-op and the
     runtime gates become `constexpr false`, so the logging code is dead-stripped.
     Always-on `NQD_ERR`/`COMPOSITOR_ERR` error logging still compiles in.
   - `1`: logging is compiled in and controlled at runtime (see layer 2).
2. **Runtime gates** (only when the flag is `1`), read once at startup from the
   environment:
   - `GFXACCEL_LOG` = `all` or a comma list of `gl,rave,dsp,nqd,comp`
     (unset ⇒ all subsystems on).
   - `GFXACCEL_LOG_VERBOSE` = `1` to also emit the per-draw / per-frame "firehose"
     tier (`*_VLOG`). Off by default, so an enabled subsystem shows milestones,
     state changes, and errors but not per-primitive spam.

## tools/gfxlog.sh

| Command | Effect | Rebuild? |
|---|---|---|
| `gfxlog.sh status` | show compile-flag + scheme env state | — |
| `gfxlog.sh off` | compile flag → 0 (stripped, ship) | yes |
| `gfxlog.sh on [gl rave dsp nqd comp] [-v]` | flag → 1; set subsystems (default `all`) + verbose | yes |
| `gfxlog.sh set <subs>` / `only <s>` | change subsystems only | no (relaunch) |
| `gfxlog.sh verbose on\|off` | toggle verbose tier only | no (relaunch) |
| `gfxlog.sh tail` | stream the unified log for `com.pocketshaver.*` | — |

The script edits the `ACCEL_LOGGING_ENABLED` line in `accel_logging.h` and the
`<EnvironmentVariables>` of `PocketShaver.xcscheme`. Subsystem/verbose changes while
the flag is already `1` only need a relaunch; flipping the flag needs a rebuild.

## Viewing logs

Output goes to the unified logging system (not stdout). Subsystems:
`com.pocketshaver.{gl,rave,dsp,nqd,compositor}` (GL has categories `engine` and `metal`).

```
tools/gfxlog.sh tail
# or directly:
xcrun simctl spawn booted log stream --level debug \
  --predicate 'subsystem BEGINSWITH "com.pocketshaver"'
```

Note: on a physical device `os_log` redacts `%s` as `<private>` (pre-existing
behavior); the Simulator shows everything.

## Adding logs in gfxaccel code

- Milestone / one-time / state-change / error → `RAVE_LOG(...)`, `DSP_LOG(...)`,
  `GL_LOG(...)`, `GL_METAL_LOG(...)`, `NQD_LOG(...)`, `COMPOSITOR_LOG(...)`.
- Anything that can fire more than once per frame (per-draw, per-blit, per-mip,
  per-present) → the `*_VLOG(...)` variant so it only appears with verbose on.
- Genuine always-on errors → `NQD_ERR(...)` / `COMPOSITOR_ERR(...)`.
- Use plain `os_log` format specifiers; no trailing `\n`.
