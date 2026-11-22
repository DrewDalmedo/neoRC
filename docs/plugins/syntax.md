# Syntax

Highlighting for languages Neovim ships no support for, defined in Lua. Each language is one spec file in `plugins/syntax/langs/`, and new files are picked up automatically.

Currently included: **HolyC** (`*.HC`, `*.hc`).

If a real syntax plugin exists for the same filetype, it wins and these rules stand down.

## Adding a language

Create `plugins/syntax/langs/mylang.lua`:

```lua
return {
    filetype = "mylang",
    extensions = { "ml", "MLG" },
    filenames = { "Mfile" },
    patterns = { [[.*/mylang%.conf]] },
    options = { commentstring = "# %s" },
    case = "match",
    rules = {
        { "mylangOperator", link = "Operator", match = [=[[-+*/=]]=] },
        { "mylangKeyword", link = "Keyword", keywords = { "if", "fn" } },
        { "mylangString", link = "String",
            region = { [["]], [["]], skip = [[\\"]] } },
    },
}
```

| Field | Description |
|---|---|
| `filetype` | The filetype name |
| `extensions` | File extensions |
| `filenames` | Exact file names |
| `patterns` | `vim.filetype.add` patterns |
| `options` | Buffer-local options |
| `case` | `"match"`, or `"ignore"` for keywords |
| `rules` | The highlighting rules, in priority order |

## Rules

A rule has a syntax group name first, a `link` to a highlight group, and exactly one of:

| Field | Matches |
|---|---|
| `keywords = { ... }` | Whole words, using the spec's `case` |
| `match = [[pat]]` | A Vim regex. Delimiters are added for you |
| `region = { start, end }` | A region, with optional `skip` |

Add `opts = "..."` for raw `:syn` arguments such as `contained`.

## Order matters

When two rules match at the same spot, the one defined **last** wins, and keywords always beat matches and regions. List rules from lowest to highest priority, with comments and strings at the bottom so they swallow any operators and keywords inside them.
