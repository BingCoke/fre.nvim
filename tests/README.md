# Tests

The test entry points run under headless Neovim and bootstrap the pinned Plenary
checkout into the ignored `.deps/` directory.

Full suite:

```powershell
.\scripts\test.ps1
```

Focused spec:

```powershell
.\scripts\test.ps1 tests/path_spec.lua
```

Git Bash and other POSIX shells can use `./scripts/test.sh` with the same
optional spec argument. `scripts/test.cmd` is also available for `cmd.exe`.
All entry points return a nonzero process status when a spec fails or cannot be
loaded.
