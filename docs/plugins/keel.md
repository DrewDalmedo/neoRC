# Keel

A focused Git interface. It covers the daily loop of reviewing, staging, committing, branching, and syncing. Open it with `<leader>g` or `:Keel`.

Keel uses the working directory's repository, or the current file's when the working directory isn't in one.

## Status view

```text
Head:     main  Add the parser
Upstream: origin/main  (ahead 1)

v Untracked files (1)
  > ? notes.txt

v Unstaged changes (1)
  v M parser.lua
v @@ -10,3 +10,4 @@
 local tokens = {}
+local depth = 0
 return tokens

v Staged changes (1)
  > M README.md

v Recent commits (2)
  a1b2c3d Add the parser
  d4e5f6a First commit
```

The view refreshes when you enter it, when Neovim regains focus, and after you save a file. A refresh never moves an active Visual selection.

### Keys

| Key | Mode | Action |
|---|---|---|
| `<Tab>` | Normal | Expand or collapse a section, file, or hunk |
| `<CR>` | Normal | Open the file at that line, or show a commit or stash |
| `s` | Normal, Visual | Stage |
| `u` | Normal, Visual | Unstage |
| `x` | Normal, Visual | Discard, after asking |
| `S` | Normal | Stage all tracked changes |
| `U` | Normal | Unstage everything |
| `cc` | Normal | Commit |
| `ca` | Normal | Amend the last commit |
| `b` | Normal | Branches |
| `f` | Normal | Fetch |
| `F` | Normal | Pull |
| `P` | Normal | Push |
| `l` | Normal | Log |
| `gr` | Normal | Refresh |
| `g?` | Normal | List these keys |
| `q` | Normal | Close |

### What `s`, `u`, and `x` act on

| Cursor or selection | Acts on |
|---|---|
| A section heading | Every file in the section |
| A file | The whole file |
| A hunk, or a diff line in Normal mode | The whole hunk |
| Lines selected in one hunk | Only those lines |
| Several files selected | Those files |

Untracked files can only be staged or discarded whole. Discarding an untracked file deletes it permanently.

If a line selection touches a missing final newline in a way Git can't represent, Keel refuses it and asks you to use the whole hunk.

## Committing

`cc` and `ca` open a message buffer in a split.

| Key | Mode | Action |
|---|---|---|
| `<C-c><C-c>` | Normal, Insert | Commit |
| `<C-c><C-k>` | Normal, Insert | Abort, asking first if there's text to lose |
| `:w`, `<C-;>` | | Save a draft |
| `g?` | Normal | List these keys |

Saving never creates a commit. Drafts live in the repository's Git directory and come back the next time you commit.

The message is committed exactly as written, so a line starting with `#` is kept. Commit hooks run as usual. If a commit or hook fails, the buffer and your message stay open with Git's reason.

## Branches

`b` opens a picker of local and remote branches.

| Key | Action |
|---|---|
| `<CR>` | Switch to the branch |
| `<C-n>` | Create a branch named after what you typed |

Choosing a remote branch switches to its local branch, or creates one that tracks it. If Git refuses a switch because it would overwrite your work, nothing changes and Keel shows why.

## Fetch, pull, and push

These run in a small terminal split, so Git, SSH, and credential helpers can ask for anything they need. The split closes on success and stays open with Git's output on failure.

| Key | Runs |
|---|---|
| `f` | `git fetch` |
| `F` | `git pull --no-edit` |
| `P` | `git push` |

If the branch has no upstream, `P` asks before publishing it. It uses `remote.pushDefault`, then `origin`, then the only remote, and otherwise lets you choose.

## Log

`l` shows the last 200 commits.

| Key | Action |
|---|---|
| `<CR>` | Show the commit |
| `+` | Load 200 more |
| `gr` | Refresh |
| `g?` | List these keys |
| `q` | Close |

The commit view has `g?` and `q`.

## Limits

- Binary files and diffs over 5,000 lines show a placeholder, but can still be staged as whole files.
- Interactive rebase, conflict resolution, bisect, cherry-pick, and worktree management are left to Git. During a merge or rebase, Keel shows the state and the conflicted files.
- Stashes are listed and can be viewed, but not created or applied.
