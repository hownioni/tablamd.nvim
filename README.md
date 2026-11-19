# gridtable.nvim

Edit [Pandoc grid tables](https://pandoc.org/MANUAL.html#extension-grid_tables) in Markdown
from Neovim: realign as you type, move between cells, and add, delete, move and sort rows and
columns.

```
+------------+-----+
| Name       | Age |
+============+=====+
| Ana        | 30  |
+------------+-----+
| José María | 4   |
| - bullets  |     |
+------------+-----+
```

It's pure Lua: the table is parsed and re-rendered without a pandoc round-trip, so cell text is
kept exactly as written. Widths use `strdisplaywidth`, so accents and wide characters align.
Pandoc is only needed for `convert`.

Requires Neovim 0.10+.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "hownioni/gridtable.nvim",
    ft = "markdown",
    opts = {},
}
```

## Usage

| Default key       | Action              | What it does                                                                |
| ----------------- | ------------------- | --------------------------------------------------------------------------- |
| `\tn`             | `new_table`         | Ask for headers (`A, B, C`) or a column count (`3`) and insert a table      |
| `\ta`             | `align`             | Realign the table (also done automatically on `InsertLeave`)                |
| `\tc`             | `convert`           | Convert a pipe/simple/grid table to a grid table with pandoc (visual too)   |
| `<Tab>` / `<S-Tab>` | `next_cell` / `prev_cell` | Next/previous cell along each row's first line, row by row; next on the last cell adds a row |
| `<CR>` / `<S-CR>` | `cell_down` / `cell_up`   | Same column, next/previous row (whole rows: use `j`/`k` inside a multi-line row); down on the last row adds a row |
| `<A-o>`           | `new_row`           | New row below the current one                                               |
| `<A-CR>`          | `new_line`          | New line inside the current row (e.g. another bullet in a cell)             |
| `<A-h>` / `<A-l>` | `move_col_left` / `move_col_right` | Move the column                                              |
| `<A-j>` / `<A-k>` | `move_row_down` / `move_row_up`    | Move the whole row (takes a count; never across the header)  |
| `\tic` / `\tiC`   | `insert_col` / `insert_col_before` | Insert a column right/left of the cursor                     |
| `\tdc`            | `delete_col`        | Delete the column                                                           |
| `\tdr`            | `delete_row`        | Delete the row and yank it (`p` on a border line pastes it back)            |
| `\tA`             | `cycle_align`       | Cycle the column's alignment: default, left, center, right                  |
| `\th`             | `toggle_header`     | Make the first row the header, or a normal row                              |
| `\ts` / `\tS`     | `sort` / `sort_desc`| Sort body rows by the column (numbers numerically, accents folded)          |
| `\tj`             | `join_row`          | Join a multi-line row into one line                                         |
| `\tb`             | `break_row`         | Break a multi-line row into one row per line                                |
| `ic` / `ac`       | `inner_cell` / `outer_cell` | Text objects: cell content / everything between the pipes           |

`\` is `<localleader>`. The navigation keys work in normal and insert mode, and only inside a
table. Elsewhere they do exactly what they did before: the key's own mapping, looked up when you
press it (so plugins that map keys late, like nvim-autopairs, still work), or Vim's built-in
behaviour. While a snippet is active they always go to the snippet.

The Alt keys follow one rule: `<A-hjkl>` move things in that direction. In a table, moving a single
line would break it, so `<A-j>`/`<A-k>` work as a table-aware version of a move-line mapping.

### blink.cmp

blink.cmp maps `<Tab>`/`<S-Tab>` in insert mode in every buffer, replacing the plugin's mapping.
Hook the table into blink's own chain instead:

```lua
keymap = {
    preset = "default",
    ["<Tab>"] = {
        "snippet_forward",
        function()
            return package.loaded.gridtable and require("gridtable").try("next_cell")
        end,
        "fallback",
    },
    ["<S-Tab>"] = {
        "snippet_backward",
        function()
            return package.loaded.gridtable and require("gridtable").try("prev_cell")
        end,
        "fallback",
    },
},
```

`try(action)` runs the action and returns `true` only when the cursor is in a table.

Counts work like Vim's: `3<Tab>`, `2<CR>`, `3<A-o>` and `2\tic` repeat, `5\tdr` deletes (and
yanks) five rows as one change, `2\tdc` deletes two columns and `3<A-j>`/`2<A-l>` move a row or
column that many places. Deleting is clamped so the table keeps one body row and one column.

Every action is also available as `:GridTable {action}`, e.g. `:GridTable sort`,
`:GridTable delete_row 3` (with a count) or `:'<,'>GridTable convert`.

Other behaviour:

- Typing `|` inside a complete row inserts `\|`, since a literal pipe in a cell must be escaped.
  Typing a new row by hand is left alone.
- `'wrap'` is turned off while the cursor is on a table line and restored after.
- New and converted tables are wrapped in `<!-- prettier-ignore-start/end -->` so prettier
  doesn't reformat them.

## Configuration

Defaults:

```lua
require("gridtable").setup({
    filetypes = { "markdown" },
    auto_align = true, -- per buffer: vim.b.gridtable_autoalign = false
    escape_pipes = true, -- per buffer: vim.b.gridtable_escape_pipes = false
    nowrap = true,
    prettier_ignore = true,
    pandoc = {
        "pandoc", "-f", "markdown",
        "-t", "markdown-pipe_tables-simple_tables-multiline_tables+grid_tables",
        "--columns=80",
    },
    which_key = true, -- register the <localleader>t groups
    keymaps = {
        -- action = key, or false to disable; see the table above for all names
        new_table = "<localleader>tn",
        -- ...
    },
})
```

## Limitations

- A table must start and end with a `+---+` border line.
- Row and column spans are not supported.
- A literal `|` in a cell must be written `\|`.

## Development

```sh
make test     # headless test suite
make format   # stylua
```

## License

MIT
