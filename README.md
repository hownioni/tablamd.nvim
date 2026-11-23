# tablamd.nvim

> [!IMPORTANT]
> **AI usage disclosure:** This plugin is vibecoded in its entirety, use it at your own risk.
> I needed something like this and had the Claude subscription lying around so I decided to make use of it.

Edit Markdown tables from Neovim: [Pandoc grid tables](https://pandoc.org/MANUAL.html#extension-grid_tables)
and ordinary pipe tables. Realign as you type, move between cells, add, delete, move and sort rows
and columns, and convert between the two formats.

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

```
| Nombre     | Edad |
| :--------- | ---: |
| Ana        |   30 |
| José María |    4 |
```

It's pure Lua: the table is parsed and re-rendered without a pandoc round-trip, so cell text is
kept exactly as written. Accents and wide characters align. Pandoc is only needed for `\tC`.

Requires Neovim 0.10+.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "hownioni/tablamd.nvim",
    ft = "markdown",
    opts = {},
}
```

## Usage

| Default key         | Action                             | What it does                                                                                                      |
| ------------------- | ---------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `\tn`               | `new_table`                        | Ask for headers (`A, B, C`) or a column count (`3`) and insert a table (format: `new_table_format`)               |
| `\ta`               | `align`                            | Realign the table (also done automatically on `InsertLeave`)                                                      |
| `\tc`               | `convert`                          | Toggle grid ↔ pipe, keeping cell text as is (anything else goes to `\tC`)                                         |
| `\tC`               | `pandoc`                           | Convert any table (pipe/simple/grid) to grid through pandoc, wrapping long cells (visual too)                     |
| `<Tab>` / `<S-Tab>` | `next_cell` / `prev_cell`          | Next/previous cell along each row's first line, row by row; next on the last cell adds a row                      |
| `<CR>` / `<S-CR>`   | `cell_down` / `cell_up`            | Same column, next/previous row (whole rows: use `j`/`k` inside a multi-line row); down on the last row adds a row |
| `<A-o>` / `<A-O>`   | `new_row` / `new_row_above`        | New row below/above the current one                                                                               |
| `<A-CR>`            | `new_line`                         | New line inside the current row (e.g. another bullet in a cell)                                                   |
| `<A-h>` / `<A-l>`   | `move_col_left` / `move_col_right` | Move the column                                                                                                   |
| `<A-j>` / `<A-k>`   | `move_row_down` / `move_row_up`    | Move the whole row (takes a count; never across the header)                                                       |
| `\tic` / `\tiC`     | `insert_col` / `insert_col_before` | Insert a column right/left of the cursor                                                                          |
| `\tdc`              | `delete_col`                       | Delete the column                                                                                                 |
| `\tdr`              | `delete_row`                       | Delete the row and yank it (`p` on a border line pastes it back)                                                  |
| `\tyr` / `\tyc`     | `duplicate_row` / `duplicate_col`  | Copy the row below it / the column right of it (cursor moves into the copy)                                       |
| `\tA`               | `cycle_align`                      | Cycle the column's alignment: default, left, center, right                                                        |
| `\th`               | `toggle_header`                    | Make the first row the header, or a normal row                                                                    |
| `\tH`               | `toggle_header_col`                | Make the first column a header column (bold row labels, protected), or a normal column                           |
| `\ts` / `\tS`       | `sort` / `sort_desc`               | Sort body rows by the column (numbers numerically, accents folded)                                                |
| `\tj`               | `join_row`                         | Join a multi-line row into one line                                                                               |
| `\tb`               | `break_row`                        | Break a multi-line row into one row per line                                                                      |
| `ic` / `ac`         | `inner_cell` / `outer_cell`        | Text objects: cell content / everything between the pipes                                                         |

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
            return package.loaded.tablamd and require("tablamd").try("next_cell")
        end,
        "fallback",
    },
    ["<S-Tab>"] = {
        "snippet_backward",
        function()
            return package.loaded.tablamd and require("tablamd").try("prev_cell")
        end,
        "fallback",
    },
},
```

`try(action)` runs the action and returns `true` only when the cursor is in a table.

Counts work like Vim's: `3<Tab>`, `2<CR>`, `3<A-o>`, `2\tic` and `2\tyr` repeat, `5\tdr`
deletes (and yanks) five rows as one change, `2\tdc` deletes two columns and `3<A-j>`/`2<A-l>`
move a row or column that many places. Deleting is clamped so the table keeps one body row and one column.

Every action is also available as `:TablaMd {action}`, e.g. `:TablaMd sort`,
`:TablaMd delete_row 3` (with a count) or `:'<,'>TablaMd convert`.

Other behaviour:

- Typing `|` inside a complete row inserts `\|`, since a literal pipe in a cell must be escaped.
  Typing a new row by hand is left alone.
- `'wrap'` is turned off while the cursor is on a table line and restored after.
- New and converted tables are wrapped in `<!-- prettier-ignore-start/end -->` so prettier
  doesn't reformat them.

## Header column

Markdown has no syntax for a header column, so `\tH` writes it the way it shows in the PDF:
every body cell of the first column in bold (`**Ana**`, list markers kept outside:
`- **item**`). The bold text is the marker, so nothing else is added to the file, and it works on
grid and pipe tables alike. A table has a header column when every non-empty body cell of its
first column is bold.

While it's on:

- A row you add and type into gets its first cell bolded too, on realign or when you move to
  another cell. A cell you're writing bold by hand (`**Pe`) is left alone.
- The column is protected: it can't be moved, deleted, duplicated or have a column inserted
  before it, and other columns can't be moved in front of it. `\tH` again turns it back into a normal column.
- Sorting by it ignores the `**` markers.
- It combines with a header row: the header row's first cell (the corner) stays plain, and
  `\th` bolds or unbolds that cell as the row stops or starts being the header.

## Pipe tables

Everything works on pipe tables too, except what needs a multi-line row or an optional header:
`new_line`, `join_row`, `break_row` and `toggle_header` say so and point to `\tc`, which converts
the table to a grid table. A pipe table's header row can't be deleted.

Realigned pipe tables are formatted exactly like [prettier](https://prettier.io) formats them
(alignment padding, minimum width 3, outer pipes), so prettier on save never fights with the
plugin, and they don't get prettier-ignore markers. `\tc` adds the markers when converting to a
grid table and removes them when converting back.

Converting grid → pipe needs a header row (`\th`) and single-line rows (`\tj`).

## Configuration

Defaults:

```lua
require("tablamd").setup({
    filetypes = { "markdown" },
    auto_align = true, -- per buffer: vim.b.tablamd_autoalign = false
    escape_pipes = true, -- per buffer: vim.b.tablamd_escape_pipes = false
    nowrap = true,
    new_table_format = "pipe", -- "grid", "pipe", or "ask" (last choice offered first)
    prettier_ignore = true, -- wrap new/converted grid tables in prettier-ignore markers
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

- A grid table must start and end with a `+---+` border line.
- Row and column spans are not supported.
- A literal `|` in a cell must be written `\|`.

## Development

```sh
make test     # headless test suite
make format   # stylua
```

## License

MIT
