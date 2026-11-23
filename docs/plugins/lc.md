# lc

Runs lcclone, an offline LeetCode-style practice tool, from Neovim. Everything it shows comes from the `lc` command.

The plugin only loads when `lc` is executable and you're not on native Windows. WSL counts as Linux. Run `:checkhealth neo.plugins.lc` to check your setup.

## Keys

| Key | Action |
|---|---|
| `<leader>tl` | Pick a problem |
| `<leader>tp` | Browse problems on the board |
| `<leader>tt` | Test the solution |
| `<leader>ts` | Submit the solution |
| `<leader>tr` | Show the last result |
| `<leader>tx` | Cancel the run |

## Commands

`:Lc` alone is `:Lc list`, and `<Tab>` completes.

| Command | Action |
|---|---|
| `:Lc list [--difficulty L] [--tag T] [--status S]` | Pick a problem. Choosing one starts it |
| `:Lc problems [filters]` | Browse problems on the board. Without filters, it keeps the current ones |
| `:Lc random [filters]` | Open a random problem |
| `:Lc show [problem]` | Show its statement |
| `:Lc start [problem] [c\|cpp]` | Set it up and open the solution beside the statement |
| `:Lc test [solution] [--std STD] [--sanitize] [--case FILE] [--lang LANG]` | Build and run the examples and your cases |
| `:Lc submit [solution] [--std STD] [--sanitize] [--lang LANG]` | Run every case and record the submission |
| `:Lc cancel` | Stop the run. A second cancel kills `lc` |
| `:Lc result` | Reopen the last result |
| `:Lc stats` | Solved and attempted, by difficulty and tag |
| `:Lc std [c\|cpp] {std}` | Set the standard for this session, such as `c++17`, `c11`, `max`, or `default` |

A problem is its number (`1`), slug (`two-sum`), or directory (`0001-two-sum`). Without one, a command uses the current buffer's problem.

When all cases pass, `submit` runs them again with ASan and UBSan, as LeetCode builds them.

## Views

The result, stats, statement, and problems board are [malleable](../development.md#malleable-buffers) views. In each one, `g?` lists its keys and `q` closes it. The result and stats share the panel at the bottom.

The picker handles quick choices: `:Lc list`, and finding a problem or choosing a tag from the board.

### Problems board

Opening the board clears the screen the way switching [projects](projects.md) does. Changed files are saved, other tabs, windows, and buffers close, and unsaved edits in a malleable view get a question first. A board already on screen just updates.

Starting a problem closes the board and puts the solution in its place, beside the statement.

| Key | Action |
|---|---|
| `<CR>` | Open the problem, as the `open` option says |
| `s` | Start it |
| `p` | Show its statement in a split and stay on the board |
| `fd` | Cycle the difficulty filter |
| `fs` | Cycle the status filter |
| `ft` | Add or remove a tag. Several tags must all match |
| `fc` | Clear the filters |
| `F` | Fuzzy-find a problem on the board |
| `gr` | Refresh |

`lc` does the filtering, and a submission updates a board that's on screen.

### Result window

| Key | Action |
|---|---|
| `a` | Add the case under the cursor to `cases.txt` |
| `<CR>` | Go to what the line is about |
| `r` | Run again |
| `<C-c>` | Cancel |

Compile errors and sanitizer reports appear as diagnostics on the solution. They and failed cases also fill the quickfix list, replacing the last run's list but never one of yours.

### Stats and statement

In stats, `<CR>` opens the board filtered by the difficulty or tag under the cursor, and `gr` refreshes. In a statement from `:Lc show`, `s` starts the problem.

## Options

See the [`lc` section of Configuration](../configuration.md#lc).

## For statuslines and autocommands

`require("neo.plugins.lc").status()` returns `""` or text such as `lc test: 3/16`.

The `User` autocommands `LcRunStart` and `LcRunDone` fire around each run. Their data holds `kind`, `target`, and `problem`. `LcRunDone` adds `verdict`, `cancelled`, `error`, `passed`, `total`, `solution`, and `sanitizer_check`.
