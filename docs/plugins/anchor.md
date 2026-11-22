# Anchor

A few files per project, each in a numbered slot you can jump to with one key.

A project is the current window's working directory, so `:lcd` and `:tcd` count, and switching with [Projects](projects.md) brings that project's list along.

## Keys

| Key | Action |
|---|---|
| `<leader>a` | Anchor the current file in the first empty slot |
| `<leader>m` | Edit the list |
| `<C-p>` | Open slot 1 |
| `<C-t>` | Open slot 2 |
| `<C-s>` | Open slot 3 |
| `<C-n>` | Open slot 4 |

## Commands

| Command | Action |
|---|---|
| `:Anchor` | Edit the list |
| `:Anchor add` | Anchor the current file |
| `:Anchor remove` | Empty the current file's slot. Other files keep their numbers |
| `:Anchor menu` | Edit the list |
| `:Anchor {N}` | Open the file in slot N |

Only files can be anchored, not listings, terminals, help, or scratch buffers.

Opening a file that's already open switches to its buffer. Otherwise it opens at the last place you were in it. If a slot's file no longer exists, Anchor says so instead of opening an empty buffer.

## Editing the list

The menu is a float with one file per line, where line N is slot N and a blank line is an empty slot. Edit it as text:

| Edit | Result |
|---|---|
| `dd` | Remove the file and move the lines below it up a slot |
| `cc<Esc>` | Empty the slot in place |
| Move a line | Move the file to another slot |
| Type a path | Anchor that file |

| Key | Action |
|---|---|
| `<CR>` | Open the file on the cursor line |
| `q`, `<Esc>` | Close |
| `:w`, `<C-;>` | Save without leaving |

Leaving the menu in any way saves it.

## Statusline

An anchored file shows its slot key before its name:

```text
[T] neo: sub/file.txt
```

A slot without a key, or one whose key now does something else in that buffer, shows its number instead:

```text
[5] neo: sub/file.txt
```

## Storage

Lists live in `stdpath("data")/neo/anchor.json` and are read fresh on every use, so several Neovim instances share them. Files inside a project are stored relative to it, and [Harbor](harbor.md) updates them when files move.

To store them elsewhere, pass `file` to `require("neo.plugins.anchor").setup()`.
