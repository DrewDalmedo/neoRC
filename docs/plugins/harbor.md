# Harbor

A file explorer you edit like text. A directory is a buffer with one entry per line, and saving applies what you changed.

Open it with `<leader>f` or `:Harbor [dir]`. With no directory, it opens the current file's directory with the cursor on that file. Harbor also handles `:e some/dir`, `nvim .`, and project switches. `:Explore` and netrw's `scp://` editing still work.

## Editing

| Edit | Result |
|---|---|
| Change a name | Rename |
| Type a new line | New file |
| Type `name/` | New directory |
| Type `a/b.txt` | New file, with its parent directories |
| `dd` | Delete |
| `dd`, go to another directory, `p` | Move |
| `yy`, `p`, change the name | Copy |
| `yy`, go to another directory, `p` | Copy there |

Edits across several directories are one save.

Each line starts with a hidden ID that lets Harbor track an entry through edits. To protect it, `0`, `^`, `I`, `cc`, and `S` work from the start of the name, and in Insert mode `<BS>`, `<C-h>`, `<C-w>`, and `<C-u>` stop there.

## Saving

Press `:w` or `<C-;>`. Harbor shows what it's about to do:

- `y` applies it.
- `n`, `q`, or `<Esc>` goes back to editing.

`:wq` shows the same question and leaves the listing open, because the save only finishes once you've answered.

## Keys

| Key | Action |
|---|---|
| `<CR>` | Open the file or directory |
| `-` | Go up a directory |
| `g.` | Show or hide dotfiles |
| `gy` | Copy the path to the clipboard |
| `gR` | Read the listing from disk |
| `g?` | List these keys |

## Safety

Before touching anything, a save is refused if:

- something changed on disk since it was listed
- a target already exists
- a file it would move or delete has unsaved changes
- it would touch a filesystem root, your home directory, or the config directory itself

Files inside the config directory can be changed.

Deletes run last and are permanent. If an operation still fails partway through, Harbor stops and reports what was done, what failed, and what never ran.

After a save, Harbor updates open buffers, working directories, and [Anchor](anchor.md) slots to follow anything that moved.

If you switch projects with unsaved Harbor edits, [Projects](projects.md) asks first. Anything but `y` keeps your edits and stays in the project.

## Options

Pass options to `require("neo.plugins.harbor").setup()` in `init.lua`:

| Option | Default | Description |
|---|---|---|
| `show_hidden` | `true` | Show dotfiles in listings |
