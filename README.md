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
| `<A-l>` / `<A-h>` | `next_cell` / `prev_cell` | Next/previous cell; next on the last cell adds a row                  |
| `<A-j>` / `<A-k>` | `cell_down` / `cell_up`   | Same column, next/previous line                                       |
| `<A-o>`           | `new_row`           | New row below the current one                                               |
| `<A-CR>`          | `new_line`          | New line inside the current row (e.g. another bullet in a cell)             |
| `<A-L>` / `<A-H>` | `move_col_right` / `move_col_left` | Move the column                                              |
| `<A-J>` / `<A-K>` | `move_row_down` / `move_row_up`    | Move the row (never across the header)                       |
| `\tic` / `\tiC`   | `insert_col` / `insert_col_before` | Insert a column right/left of the cursor                     |
| `\tdc`            | `delete_col`        | Delete the column                                                           |
| `\tdr`            | `delete_row`        | Delete the row and yank it (`p` on a border line pastes it back)            |
| `\tA`             | `cycle_align`       | Cycle the column's alignment: default, left, center, right                  |
| `\th`             | `toggle_header`     | Make the first row the header, or a normal row                              |
| `\ts` / `\tS`     | `sort` / `sort_desc`| Sort body rows by the column (numbers numerically, accents folded)          |
| `\tj`             | `join_row`          | Join a multi-line row into one line                                         |
| `\tb`             | `break_row`         | Break a multi-line row into one row per line                                |
| `ic` / `ac`       | `inner_cell` / `outer_cell` | Text objects: cell content / everything between the pipes           |

`\` is `<localleader>`. The `<A-…>` keys are only active inside a table. Elsewhere they run
whatever global mapping the key had (e.g. a move-line mapping on `<A-j>`).

Every action is also available as `:GridTable {action}`, e.g. `:GridTable sort` or
`:'<,'>GridTable convert`.

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
