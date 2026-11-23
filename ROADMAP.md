# Roadmap

Ideas for future features, roughly grouped. Top picks are marked with ★.

## Writing notes

### ★ Date-aware sorting

`\ts` compares `11/11`-style dates as text, so `9/11` sorts after `11/11`. Detect `dd/mm` and
`dd/mm/yyyy` (maybe `yyyy-mm-dd` too) in the sort key and compare chronologically. The key
already has numeric and text cases (`sort_key` in `edit.lua`), so dates become a third case.

### Paste from a spreadsheet, export to CSV

Copying a range from LibreOffice or Google Sheets puts tab-separated text on the clipboard.
`\tp` would turn it into a table (in `new_table_format`), and an export action would write the
table under the cursor as CSV (or copy it as TSV). Useful for tables like contact lists.

### Per-column widths

`max_width` wraps the whole table to a width, shrinking the widest columns first. A command to fix a
single column's width (kept on realign) would give finer control over the PDF layout.

### Table captions

Insert or edit pandoc's `Table: …` caption line below the table (or `: …`), so the PDF gets a
numbered caption. Keep it attached when the table is converted or moved.

## Editing

### ★ Repeat with `.`

Make table actions dot-repeatable (e.g. `\tdr` then `...`), including counts. The usual
approach is going through `operatorfunc` (`g@l`) so `.` replays the action.

### Column text object and column yank/paste

Yank a whole column (cells of every row) and paste it as a new column, in the same table or
another one. Could use a register with a recognizable shape or a plugin-local register.

### Transpose

Swap rows and columns. For grid tables, only when rows are single lines (or join them first).

## Seeing where you are

### ★ Lualine component

Show the current column's header and row number, e.g. `Responsables · row 3`, for wide tables
where the header has scrolled off-screen. Expose a function returning the string (empty outside
a table) that lualine (or any statusline) can call.

### Warnings for broken tables

Report malformed tables with `vim.diagnostic` (wrong cell count, border with the wrong number of
columns, missing border) as soon as they break, instead of only warning on `InsertLeave` or
finding out when compiling the PDF.

## Before publishing

### `:help tablamd`

A vimdoc help file (`doc/tablamd.txt`) covering setup, options, actions, keymaps and the
blink.cmp integration.

### `:checkhealth tablamd`

Check the Neovim version, whether `pandoc` is available (for `\tC`), and report keymap
conflicts or a completion plugin owning `<Tab>` without the `try()` hook.

### GitHub Actions

Run `make test` (and `make lint`) on stable and nightly Neovim for every push and pull request.
