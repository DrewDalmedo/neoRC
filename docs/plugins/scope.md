# Scope

Fuzzy file finding and live grep from the working directory.

| Key | Command | Action |
|---|---|---|
| `<leader>l` | `:ScopeFiles` | Find files |
| `<leader>h` | `:ScopeGrep` | Live grep |

## Picker keys

Scope, Projects, Keel's branch list, and lc all use the same picker.

| Key | Mode | Action |
|---|---|---|
| `<CR>` | Insert, Normal | Choose the highlighted item |
| `<Up>`, `<Down>` | Insert, Normal | Move the selection |
| `j`, `k` | Normal | Move the selection |
| `gg`, `go` | Normal | Go to the first result |
| `G` | Normal | Go to the last result |
| `<Esc>` | Normal | Close |

The prompt starts in Insert mode, so press `<Esc>` twice to close it.

## Finding files

The scan runs in the background and streams results as it finds them. It honors `.gitignore` files, even outside Git repositories, and stops at 50,000 files or 12 directories deep.

These directories are always skipped:

```text
.git  .svn  .hg  node_modules  __pycache__  .cache  vendor
target  .venv  env  .tox  dist  build  .next
```

## Live grep

Grep starts after two characters and shows up to 1,000 results. It uses the first available tool:

1. `rg` (ripgrep)
2. `findstr`, on Windows
3. `grep`

`.gitignore` rules apply with all three. ripgrep handles them itself, and Scope filters the others' results.
