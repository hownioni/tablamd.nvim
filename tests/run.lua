-- Headless test runner: `make test`
-- nvim --headless -u NONE -i NONE --cmd "set rtp^=." -l tests/run.lua
vim.g.maplocalleader = "\\"
vim.o.swapfile = false
vim.o.undolevels = 1000
vim.cmd("filetype on")

vim.cmd("runtime plugin/tablamd.lua") -- -u NONE skips plugin/
local gt = require("tablamd")
gt.setup({ which_key = false })

local api = vim.api
local passed, failed = 0, {}

local function keys(k)
    api.nvim_feedkeys(vim.keycode(k), "xt", false)
end

--- Fresh markdown buffer with `lines`, cursor at { lnum, col } (col 0-based).
local function buf(lines, cursor)
    vim.cmd("enew!")
    vim.bo.filetype = "markdown"
    api.nvim_buf_set_lines(0, 0, -1, false, lines)
    -- start a new undo block so tests can check what a single `u` does
    vim.bo.undolevels = vim.bo.undolevels
    api.nvim_win_set_cursor(0, cursor or { 1, 0 })
end

local function lines()
    return api.nvim_buf_get_lines(0, 0, -1, false)
end

local function cursor()
    return api.nvim_win_get_cursor(0)
end

local function eq(got, want, what)
    if not vim.deep_equal(got, want) then
        error(("%s\n  want: %s\n  got:  %s"):format(what or "mismatch", vim.inspect(want), vim.inspect(got)), 2)
    end
end

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed[#failed + 1] = name .. ": " .. tostring(err)
    end
end

-- the cell text under the cursor, for checking cursor placement
local function cell_text()
    local l, col = api.nvim_get_current_line(), cursor()[2]
    return l:sub(col + 1):match("^([^|]-)%s*|")
end

local MESSY = {
    "+---+---+",
    "| Name | Age |",
    "+===+===+",
    "| Ana | 30 |",
    "+---+---+",
    "| José María | 4 |",
    "+---+---+",
}
local ALIGNED = {
    "+------------+-----+",
    "| Name       | Age |",
    "+============+=====+",
    "| Ana        | 30  |",
    "+------------+-----+",
    "| José María | 4   |",
    "+------------+-----+",
}

test("align realigns, counting accents by display width", function()
    buf(MESSY, { 4, 3 })
    gt.call("align")
    eq(lines(), ALIGNED)
end)

test("align keeps the cursor in the same cell and offset", function()
    buf(MESSY, { 6, 17 }) -- on the `4`
    gt.call("align")
    eq(cell_text(), "4")
end)

test("next_cell / prev_cell", function()
    buf(ALIGNED, { 4, 2 })
    gt.call("next_cell")
    eq(cell_text(), "30")
    gt.call("next_cell")
    eq(cell_text(), "José María")
    gt.call("prev_cell")
    eq(cell_text(), "30")
end)

test("next_cell on the last cell adds a row", function()
    buf(ALIGNED, { 6, 15 })
    gt.call("next_cell")
    eq(#lines(), 9)
    eq(lines()[8], "|            |     |")
    eq(cursor(), { 8, 2 })
end)

test("cell_down / cell_up skip borders", function()
    buf(ALIGNED, { 2, 15 })
    gt.call("cell_down")
    eq(cell_text(), "30")
    gt.call("cell_down")
    eq(cursor()[1], 6)
    gt.call("cell_up")
    eq(cursor()[1], 4)
end)

test("new_row on the header goes below the separator", function()
    buf(ALIGNED, { 2, 2 })
    gt.call("new_row")
    eq(lines()[3], ALIGNED[3])
    eq(lines()[4], "|            |     |")
    eq(lines()[5], "+------------+-----+")
    eq(cursor(), { 4, 2 })
end)

test("new_row_above adds a row above the current one", function()
    buf(ALIGNED, { 6, 2 })
    gt.call("new_row_above")
    eq(lines()[5], "+------------+-----+")
    eq(lines()[6], "|            |     |")
    eq(lines()[7], "+------------+-----+")
    eq(lines()[8], "| José María | 4   |")
    eq(cursor(), { 6, 2 })
end)

test("new_row_above on the first body row stays below the header", function()
    buf(ALIGNED, { 4, 2 })
    gt.call("new_row_above")
    eq(lines()[3], ALIGNED[3])
    eq(lines()[4], "|            |     |")
    eq(lines()[5], "+------------+-----+")
    eq(lines()[6], "| Ana        | 30  |")
end)

test("new_row_above does nothing on the header", function()
    buf(ALIGNED, { 2, 2 })
    gt.call("new_row_above")
    eq(lines(), ALIGNED)
end)

test("new_row_above in a headerless table adds a first row", function()
    buf({ "+-----+", "| a   |", "+-----+" }, { 2, 2 })
    gt.call("new_row_above")
    eq(lines(), { "+---+", "|   |", "+---+", "| a |", "+---+" })
    eq(cursor(), { 2, 2 })
end)

test("duplicate_row copies the row below it, cursor in the copy", function()
    buf(ALIGNED, { 4, 3 })
    gt.call("duplicate_row")
    eq(lines()[5], "+------------+-----+")
    eq(lines()[6], "| Ana        | 30  |")
    eq(lines()[7], "+------------+-----+")
    eq(lines()[8], "| José María | 4   |")
    eq(cursor(), { 6, 3 })
end)

test("duplicate_row copies every line of a multi-line row", function()
    buf({ "+---+---+", "| a | 1 |", "| b | 2 |", "+---+---+" }, { 3, 2 })
    gt.call("duplicate_row")
    eq(lines(), { "+---+---+", "| a | 1 |", "| b | 2 |", "+---+---+", "| a | 1 |", "| b | 2 |", "+---+---+" })
    eq(cursor(), { 6, 2 })
end)

test("duplicate_row on the header adds a body row below the separator", function()
    buf(ALIGNED, { 2, 2 })
    gt.call("duplicate_row")
    eq(lines()[3], ALIGNED[3])
    eq(lines()[4], "| Name       | Age |")
    eq(lines()[5], "+------------+-----+")
    eq(lines()[6], "| Ana        | 30  |")
end)

test("duplicate_col copies the column and its alignment to the right", function()
    buf(ALIGNED, { 4, 15 })
    gt.call("duplicate_col")
    eq(lines()[2], "| Name       | Age | Age |")
    eq(lines()[4], "| Ana        | 30  | 30  |")
    eq(lines()[6], "| José María | 4   | 4   |")
    eq(cursor(), { 4, 21 })
end)

test("duplicate_row and duplicate_col undo in one u", function()
    buf(ALIGNED, { 4, 2 })
    gt.call("duplicate_row")
    keys("u")
    eq(lines(), ALIGNED)
    buf(ALIGNED, { 4, 2 })
    gt.call("duplicate_col")
    keys("u")
    eq(lines(), ALIGNED)
end)

test("new_line adds a continuation line in the same column", function()
    buf(ALIGNED, { 4, 15 })
    gt.call("new_line")
    eq(lines()[5], "|            |     |")
    eq(cursor(), { 5, 15 })
end)

test("auto-align on InsertLeave, undone with a single u", function()
    buf(ALIGNED, { 4, 2 })
    keys("ea Lucía<Esc>")
    eq(lines()[4], "| Ana Lucía  | 30  |")
    buf(ALIGNED, { 4, 2 })
    keys("ea Lucía Fernández<Esc>")
    eq(lines()[1], "+---------------------+-----+")
    keys("u")
    eq(lines(), ALIGNED)
end)

test("auto-align honours b:tablamd_autoalign = false", function()
    buf(ALIGNED, { 4, 2 })
    vim.b.tablamd_autoalign = false
    keys("ea Lucía Fernández<Esc>")
    eq(lines()[1], ALIGNED[1])
end)

test("a typed | inside a complete row is escaped", function()
    buf(ALIGNED, { 4, 2 })
    keys("ea | B<Esc>")
    eq(lines()[4], "| Ana \\| B   | 30  |")
end)

test("a typed | is left alone when building a row by hand", function()
    buf({ "+---+---+", "| a | b |", "+---+---+" }, { 3, 0 })
    keys("O| x | y |<Esc>")
    eq(lines()[3], "| x | y |")
end)

test("a malformed table warns on InsertLeave", function()
    local msgs = {}
    local orig = vim.notify
    vim.notify = function(m)
        msgs[#msgs + 1] = m
    end
    buf({ "+---+---+", "| a | b |", "+---+", "| c | d |", "+---+---+" }, { 2, 2 })
    keys("ix<Esc>")
    vim.notify = orig
    eq(#msgs, 1)
    assert(msgs[1]:find("border has 1 columns"), msgs[1])
end)

local SMALL = {
    "+---+----+",
    "| a | bb |",
    "+:==+===:+",
    "| 1 | 22 |",
    "+---+----+",
}

test("insert_col adds an empty column to the right", function()
    buf(SMALL, { 4, 2 })
    gt.call("insert_col")
    eq(lines(), {
        "+---+---+----+",
        "| a |   | bb |",
        "+:==+===+===:+",
        "| 1 |   | 22 |",
        "+---+---+----+",
    })
    eq(cursor(), { 4, 6 })
end)

test("insert_col_before adds a column to the left", function()
    buf(SMALL, { 2, 2 })
    gt.call("insert_col_before")
    eq(lines()[2], "|   | a | bb |")
    eq(cursor(), { 2, 2 })
end)

test("delete_col removes the column, alignment included", function()
    buf(SMALL, { 4, 6 })
    gt.call("delete_col")
    eq(lines(), { "+---+", "| a |", "+:==+", "| 1 |", "+---+" })
    gt.call("delete_col") -- the only column: refused
    eq(lines()[2], "| a |")
end)

test("move_col_right / left carry cells and alignment", function()
    buf(SMALL, { 4, 2 })
    gt.call("move_col_right")
    eq(lines(), {
        "+----+---+",
        "| bb | a |",
        "+===:+:==+",
        "| 22 | 1 |",
        "+----+---+",
    })
    eq(cell_text(), "1")
    gt.call("move_col_right") -- already last: no-op
    eq(cell_text(), "1")
    gt.call("move_col_left")
    eq(lines(), SMALL)
end)

test("column ops work from a border line", function()
    buf(SMALL, { 5, 6 }) -- second segment of the bottom border
    gt.call("delete_col")
    eq(lines()[2], "| a |")
    eq(cursor(), { 5, 1 })
end)

local ROWS = {
    "+---+---+",
    "| H | h |",
    "+===+===+",
    "| a | 1 |",
    "|   | x |",
    "+---+---+",
    "| b | 2 |",
    "+---+---+",
    "| c | 3 |",
    "+---+---+",
}

test("delete_row removes a multi-line row and yanks it", function()
    buf(ROWS, { 5, 6 })
    gt.call("delete_row")
    eq(lines(), { ROWS[1], ROWS[2], ROWS[3], ROWS[7], ROWS[8], ROWS[9], ROWS[10] })
    eq(cell_text(), "2")
    eq(vim.fn.getreg('"'), "| a | 1 |\n|   | x |\n+---+---+\n")
    eq(vim.fn.getregtype('"'), "V")
    -- paste it back below a border
    api.nvim_win_set_cursor(0, { 3, 0 })
    keys("p")
    eq(lines(), ROWS)
end)

test("delete_row on the last row keeps the bottom border", function()
    buf(ROWS, { 9, 2 })
    gt.call("delete_row")
    eq(#lines(), 8)
    eq(lines()[8], "+---+---+")
    eq(cell_text(), "b")
end)

test("delete_row refuses the only body row", function()
    buf({ "+---+", "| H |", "+===+", "| a |", "+---+" }, { 4, 2 })
    gt.call("delete_row")
    eq(#lines(), 5)
end)

test("deleting the header leaves a headerless table with its alignment", function()
    buf({ "+---+", "| H |", "+:=:+", "| a |", "+---+", "| b |", "+---+" }, { 2, 2 })
    gt.call("delete_row")
    eq(lines(), { "+:-:+", "| a |", "+---+", "| b |", "+---+" })
end)

test("move_row_down / up swap whole rows, not across the header", function()
    buf(ROWS, { 5, 6 })
    gt.call("move_row_down")
    eq(lines(), { ROWS[1], ROWS[2], ROWS[3], ROWS[7], ROWS[6], ROWS[4], ROWS[5], ROWS[8], ROWS[9], ROWS[10] })
    eq(cursor(), { 7, 6 })
    gt.call("move_row_up")
    eq(lines(), ROWS)
    gt.call("move_row_up") -- would cross the header
    eq(lines(), ROWS)
end)

test("cycle_align cycles the header separator", function()
    buf(ALIGNED, { 4, 2 })
    local seen = {}
    for _ = 1, 4 do
        gt.call("cycle_align")
        seen[#seen + 1] = lines()[3]
    end
    eq(seen, {
        "+:===========+=====+",
        "+:==========:+=====+",
        "+===========:+=====+",
        "+============+=====+",
    })
    eq(cell_text(), "Ana")
end)

test("cycle_align uses the top border in a headerless table", function()
    buf({ "+---+---+", "| a | b |", "+---+---+" }, { 2, 6 })
    gt.call("cycle_align")
    eq(lines()[1], "+---+:--+")
    eq(lines()[3], "+---+---+")
end)

test("ic / ac text objects", function()
    buf(ALIGNED, { 6, 4 })
    keys("yic")
    eq(vim.fn.getreg('"'), "José María")
    keys("yac")
    eq(vim.fn.getreg('"'), " José María ")
    keys("vicy")
    eq(vim.fn.getreg('"'), "José María")
    api.nvim_win_set_cursor(0, { 4, 16 })
    keys("cicX<Esc>")
    eq(lines()[4], "| Ana        | X   |")
end)

test("cic in an empty cell types inside it", function()
    buf({ "+---+---+", "| a |   |", "+---+---+" }, { 2, 6 })
    keys("cicnew<Esc>")
    eq(lines()[2], "| a | new |")
end)

test("toggle_header moves alignment between top border and separator", function()
    buf({ "+:--+", "| a |", "+---+", "| b |", "+---+" }, { 2, 2 })
    gt.call("toggle_header")
    eq(lines(), { "+---+", "| a |", "+:==+", "| b |", "+---+" })
    gt.call("toggle_header")
    eq(lines(), { "+:--+", "| a |", "+---+", "| b |", "+---+" })
end)

test("toggle_header needs two rows", function()
    buf({ "+---+", "| a |", "+---+" }, { 2, 2 })
    gt.call("toggle_header")
    eq(lines()[3], "+---+")
end)

local function body_col(c)
    local out = {}
    for _, l in ipairs(lines()) do
        if l:match("^|") then
            out[#out + 1] = vim.trim(vim.split(l, "|", { plain = true })[c + 1])
        end
    end
    return out
end

local NAMES = {
    "+----+----+",
    "| N  | V  |",
    "+====+====+",
    "| ñu | 10 |",
    "+----+----+",
    "| Óscar | 9 |",
    "+----+----+",
    "| nube | 2 |",
    "+----+----+",
    "| | 2 |",
    "+----+----+",
    "| ana | x |",
    "+----+----+",
}

test("sort folds accents, puts ñ after n and empties last", function()
    buf(NAMES, { 8, 2 }) -- on "nube"
    gt.call("sort")
    eq(body_col(1), { "N", "ana", "nube", "ñu", "Óscar", "" })
    eq(cell_text(), "nube")
end)

test("sort compares numbers numerically and is stable", function()
    buf(NAMES, { 4, 2 })
    vim.cmd("normal! 0f1") -- cursor on "10", column 2
    gt.call("sort")
    eq(body_col(2), { "V", "2", "2", "9", "10", "x" })
    eq(body_col(1), { "N", "nube", "", "Óscar", "ñu", "ana" })
    gt.call("sort_desc")
    eq(body_col(2), { "V", "x", "10", "9", "2", "2" })
end)

local MULTI = {
    "+--------+---+",
    "| uno    | 1 |",
    "| dos    |   |",
    "|   tres | 3 |",
    "+--------+---+",
}

test("join_row merges a multi-line row", function()
    buf(MULTI, { 3, 2 })
    gt.call("join_row")
    eq(lines(), { "+--------------+-----+", "| uno dos tres | 1 3 |", "+--------------+-----+" })
end)

test("break_row breaks a row into one row per line", function()
    buf(MULTI, { 3, 2 })
    gt.call("break_row")
    eq(lines(), {
        "+--------+---+",
        "| uno    | 1 |",
        "+--------+---+",
        "| dos    |   |",
        "+--------+---+",
        "|   tres | 3 |",
        "+--------+---+",
    })
    eq(cell_text(), "dos")
end)

test("break_row refuses the header", function()
    buf({ "+---+", "| a |", "| b |", "+===+", "| c |", "+---+" }, { 2, 2 })
    gt.call("break_row")
    eq(#lines(), 6)
end)

test("<A-j>/<A-k> move rows inside a table, with a count", function()
    buf(ROWS, { 4, 2 })
    keys("<A-j>")
    eq(cell_text(), "a")
    eq(cursor()[1], 6)
    keys("<A-k>")
    eq(lines(), ROWS)
    keys("5<A-j>") -- clamped to the last row
    eq(lines()[9], "|   | x |")
    eq(cell_text(), "a")
    keys("i<A-k><Esc>") -- insert mode too
    eq(lines()[6], "| a | 1 |")
end)

test("<Tab>/<S-Tab> move between cells in insert and normal mode", function()
    buf(ALIGNED, { 4, 2 })
    keys("i<Tab>")
    eq(cell_text(), "30")
    keys("<S-Tab><Esc>")
    eq(cell_text(), "Ana")
    keys("<Tab>")
    eq(cell_text(), "30")
end)

test("<CR>/<S-CR> move down/up; <CR> on the last row adds one", function()
    buf(ALIGNED, { 2, 15 })
    keys("<CR>")
    eq(cell_text(), "30")
    keys("i<CR><Esc>")
    eq(cursor()[1], 6)
    keys("<S-CR>")
    eq(cursor()[1], 4)
    api.nvim_win_set_cursor(0, { 6, 15 })
    keys("<CR>")
    eq(#lines(), 9)
    eq(cursor(), { 8, 15 })
end)

test("outside a table <Tab>/<CR> keep their built-in behaviour", function()
    buf({ "a" }, { 1, 0 })
    keys("A<Tab>b<CR>c<Esc>")
    eq(lines(), { "a\tb", "c" })
end)

test("fallback finds global mappings created after attaching", function()
    buf({ "a" }, { 1, 0 })
    -- like nvim-autopairs, which maps <CR> on the first InsertEnter
    vim.keymap.set("i", "<CR>", function()
        return "<CR>late"
    end, { expr = true })
    keys("A<CR><Esc>")
    vim.keymap.del("i", "<CR>")
    eq(lines(), { "a", "late" })
end)

test("fallback doesn't re-encode raw keys from an expr mapping", function()
    buf({ "a" }, { 1, 0 })
    -- nvim-autopairs style: returns already-encoded keys, replace_keycodes off
    vim.keymap.set("i", "<CR>", function()
        return vim.keycode("<C-g>u<CR>raw")
    end, { expr = true, replace_keycodes = false })
    keys("A<CR><Esc>")
    vim.keymap.del("i", "<CR>")
    eq(lines(), { "a", "raw" })
end)

test("<Tab> belongs to an active snippet", function()
    buf(ALIGNED, { 4, 2 })
    keys("ciw")
    vim.snippet.expand("${1:uno} ${2:dos}")
    keys("<Tab>")
    eq(vim.fn.mode(), "s") -- selected the snippet's second field, not the next cell
    vim.snippet.stop()
    keys("<Esc>")
end)

local TALL = {
    "+-------+-----+",
    "| Act 1 | - a |",
    "|       | - b |",
    "+-------+-----+",
    "| Act 2 | - c |",
    "|       | - d |",
    "+-------+-----+",
}

test("<CR>/<S-CR> move by whole rows in multi-line rows", function()
    buf(TALL, { 2, 10 }) -- "- a"
    keys("<CR>")
    eq(cursor(), { 5, 10 })
    buf(TALL, { 3, 10 }) -- "- b", second line of the first row
    keys("i<CR><Esc>")
    eq(cell_text(), "- c")
    keys("<S-CR>")
    eq(cursor()[1], 2)
    api.nvim_win_set_cursor(0, { 6, 10 }) -- second line of the last row
    keys("<CR>")
    eq(#lines(), 9)
    eq(cursor(), { 8, 10 })
end)

test("<CR>/<S-CR> from a border go to the row below/above it", function()
    buf(TALL, { 4, 9 })
    keys("<CR>")
    eq(cursor()[1], 5)
    buf(TALL, { 4, 9 })
    keys("<S-CR>")
    eq(cursor()[1], 2)
    buf(TALL, { 1, 9 })
    keys("<CR>")
    eq(cursor()[1], 2)
end)

test("<Tab>/<S-Tab> go row by row in multi-line rows", function()
    buf(TALL, { 2, 10 }) -- "- a", last cell of the first row's first line
    keys("<Tab>")
    eq(cursor(), { 5, 2 }) -- "Act 2", not the continuation line
    keys("<S-Tab>")
    eq(cursor(), { 2, 10 })
    api.nvim_win_set_cursor(0, { 3, 2 }) -- first cell of a continuation line
    keys("<S-Tab>")
    eq(cursor(), { 2, 10 }) -- that row's first line, last cell
    api.nvim_win_set_cursor(0, { 6, 10 }) -- last cell of the last row's continuation line
    keys("<Tab>")
    eq(#lines(), 9)
    eq(cursor(), { 8, 2 })
end)

test("counts: 3\\tdr deletes and yanks three rows as one change", function()
    buf(NAMES, { 4, 2 })
    keys("3\\tdr")
    eq(body_col(1), { "N", "", "ana" })
    local yanked = vim.split(vim.fn.getreg('"'), "\n", { trimempty = true })
    eq(#yanked, 6) -- three rows, each with its border
    keys("u")
    eq(lines(), NAMES)
end)

test("counts: deleting rows always leaves one body row", function()
    buf(NAMES, { 6, 2 })
    keys("99\\tdr")
    eq(body_col(1), { "N", "ñu" })
    keys("u")
    keys("99\\tdr") -- again from the second body row: keeps the first
    eq(#vim.tbl_filter(function(l)
        return l:match("^|")
    end, lines()), 2)
end)

test("counts: delete_col, insert_col, move_col", function()
    local T = { "+---+---+---+---+", "| a | b | c | d |", "+---+---+---+---+" }
    buf(T, { 2, 6 }) -- on b
    keys("2\\tdc")
    eq(lines()[2], "| a | d |")
    keys("u")
    keys("2\\tic")
    eq(lines()[2], "| a | b |   |   | c | d |")
    buf(T, { 2, 2 })
    keys("2<A-l>")
    eq(lines()[2], "| b | c | a | d |")
    eq(cell_text(), "a")
    keys("9<A-h>")
    eq(lines()[2], T[2])
end)

test("counts: 2<Tab>, 2<CR>, 2<A-o>", function()
    buf(TALL, { 2, 2 })
    keys("2<Tab>")
    eq(cursor(), { 5, 2 })
    buf(TALL, { 2, 2 })
    keys("2<CR>")
    eq(#lines(), 9) -- past the last row: one new row
    buf(TALL, { 2, 2 })
    keys("2<A-o>")
    eq(#lines(), 11)
end)

test(":TablaMd takes a count argument", function()
    buf(NAMES, { 4, 2 })
    vim.cmd("TablaMd delete_row 2")
    eq(body_col(1), { "N", "nube", "", "ana" })
end)

test("widths don't depend on window options (wrap + linebreak + breakindent)", function()
    -- strdisplaywidth() counts wrapping padding for text wider than the window
    -- (the break must fall inside a word, so it isn't a multiple of 8 characters)
    local long = "uno " .. ("palabra "):rep(12) .. "fin"
    buf({ "+---+---+", "| " .. long .. " | b |", "+---+---+" }, { 2, 2 })
    vim.wo.wrap, vim.wo.linebreak, vim.wo.breakindent = true, true, true
    gt.call("align")
    vim.wo.wrap, vim.wo.linebreak, vim.wo.breakindent = false, false, false
    eq(lines()[1], "+-" .. ("-"):rep(#long) .. "-+---+")
end)

-- Pipe tables ------------------------------------------------------------------

local PIPE = {
    "| Nombre     | Edad |",
    "| :--------- | ---: |",
    "| Ana        |   30 |",
    "| José María |    4 |",
}

test("pipe: realign matches prettier, outer pipes added", function()
    buf({ "a | b", "--|:-:", "1 | 22" }, { 1, 0 })
    gt.call("align")
    eq(lines(), { "| a   |  b  |", "| --- | :-: |", "| 1   | 22  |" })
end)

test("pipe: a paragraph line with a pipe above the header isn't part of it", function()
    buf({ "texto | con pipe", "| a | b |", "|---|---|", "| 1 | 2 |" }, { 4, 2 })
    gt.call("align")
    eq(lines()[1], "texto | con pipe")
    eq(lines()[2], "| a   | b   |")
end)

test("pipe: Tab/CR navigation and the cursor in a right-aligned cell", function()
    buf(PIPE, { 3, 2 })
    keys("<Tab>")
    eq(cell_text(), "30")
    keys("<CR>")
    eq(cell_text(), "4")
    keys("<S-CR><S-Tab>")
    eq(cell_text(), "Ana")
    api.nvim_win_set_cursor(0, { 4, 20 }) -- on "4" (é and í are two bytes each)
    gt.call("align")
    eq(cursor(), { 4, 20 })
end)

test("pipe: new rows are single lines, no borders", function()
    buf(PIPE, { 4, 20 })
    keys("<Tab>")
    eq(lines()[5], "|            |      |")
    eq(cursor(), { 5, 2 })
    keys("<A-o>")
    eq(#lines(), 6)
end)

test("pipe: new_row_above and <A-O>", function()
    buf(PIPE, { 4, 2 })
    keys("<A-O>")
    eq(lines()[3], PIPE[3])
    eq(lines()[4], "|            |      |")
    eq(lines()[5], PIPE[4])
    eq(cursor(), { 4, 2 })
end)

test("pipe: duplicate_row and duplicate_col keep the alignment", function()
    buf(PIPE, { 3, 15 })
    gt.call("duplicate_col")
    eq(lines(), {
        "| Nombre     | Edad | Edad |",
        "| :--------- | ---: | ---: |",
        "| Ana        |   30 |   30 |",
        "| José María |    4 |    4 |",
    })
    gt.call("duplicate_row")
    eq(lines()[4], "| Ana        |   30 |   30 |")
    eq(lines()[5], "| José María |    4 |    4 |")
end)

test("pipe: delete rows with a count; the header stays", function()
    buf(PIPE, { 3, 2 })
    keys("5\\tdr") -- clamped: keeps one body row
    eq(lines(), { "| Nombre     | Edad |", "| :--------- | ---: |", "| José María |    4 |" })
    eq(vim.fn.getreg('"'), "| Ana        |   30 |\n")
    buf(PIPE, { 1, 2 })
    keys("\\tdr")
    eq(lines(), PIPE)
end)

test("pipe: columns and alignment", function()
    buf(PIPE, { 3, 2 })
    keys("\\tic")
    eq(lines()[2], "| :--------- | --- | ---: |")
    keys("<A-l>")
    eq(lines()[1], "| Nombre     | Edad |     |")
    eq(lines()[2], "| :--------- | ---: | --- |")
    buf(PIPE, { 3, 2 })
    keys("\\tA") -- left -> center
    eq(lines()[2], "| :--------: | ---: |")
    eq(lines()[3], "|    Ana     |   30 |")
end)

test("pipe: sort keeps the header", function()
    buf(PIPE, { 3, 2 })
    keys("\\tS")
    eq(lines()[3], "| José María |    4 |")
    eq(lines()[1], PIPE[1])
end)

test("pipe: grid-only actions refuse", function()
    for _, k in ipairs({ "<A-CR>", "\\th", "\\tb" }) do
        buf(PIPE, { 3, 2 })
        keys(k)
        eq(lines(), PIPE, k)
    end
end)

test("pipe: a typed | inside a row is escaped", function()
    buf(PIPE, { 3, 4 })
    keys("a | x<Esc>")
    eq(lines()[3], "| Ana \\| x   |   30 |")
end)

test("convert toggles grid -> pipe -> grid, handling prettier markers", function()
    local G = {
        "<!-- prettier-ignore-start -->",
        "",
        "+---+---+",
        "| a | b |",
        "+:==+==:+",
        "| 1 | 2 |",
        "+---+---+",
        "",
        "<!-- prettier-ignore-end -->",
    }
    buf(G, { 6, 6 }) -- on "2"
    keys("\\tc")
    eq(lines(), { "| a   |   b |", "| :-- | --: |", "| 1   |   2 |" })
    eq(cell_text(), "2")
    keys("\\tc")
    eq(lines(), G)
    eq(cell_text(), "2")
end)

test("convert to pipe refuses multi-line rows and headerless tables", function()
    buf(MULTI, { 2, 2 })
    keys("\\tc")
    eq(lines(), MULTI)
    buf({ "+---+", "| a |", "+---+" }, { 2, 2 })
    keys("\\tc")
    eq(lines(), { "+---+", "| a |", "+---+" })
end)

test("insert_table in pipe format", function()
    buf({ "" }, { 1, 0 })
    require("tablamd.convert").insert_table("Uno, Dos", "pipe")
    vim.cmd.stopinsert()
    eq(lines(), { "| Uno | Dos |", "| --- | --- |", "|     |     |" })
    eq(cursor(), { 3, 2 })
    buf({ "" }, { 1, 0 })
    require("tablamd.convert").insert_table("2", "pipe")
    vim.cmd.stopinsert()
    eq(lines()[1], "|     |     |")
end)

test("new_table makes a pipe table by default", function()
    local inp = vim.ui.input
    vim.ui.input = function(_, cb)
        cb("A, B")
    end
    buf({ "" }, { 1, 0 })
    gt.call("new_table")
    vim.cmd.stopinsert()
    vim.ui.input = inp
    eq(lines(), { "| A   | B   |", "| --- | --- |", "|     |     |" })
end)

test('new_table_format = "ask" offers the last choice first', function()
    local offered = {}
    local sel, inp = vim.ui.select, vim.ui.input
    vim.ui.select = function(items, _, cb)
        offered[#offered + 1] = items[1]
        cb("pipe")
    end
    vim.ui.input = function(_, cb)
        cb("A, B")
    end
    gt.config.new_table_format = "ask"
    buf({ "" }, { 1, 0 })
    gt.call("new_table")
    vim.cmd.stopinsert()
    eq(lines()[2], "| --- | --- |")
    buf({ "" }, { 1, 0 })
    gt.call("new_table")
    vim.cmd.stopinsert()
    gt.config.new_table_format = gt.defaults.new_table_format
    vim.ui.select, vim.ui.input = sel, inp
    eq(offered, { "pipe", "pipe" })
end)

test("try() runs an action only inside a table", function()
    buf({ "a" }, { 1, 0 })
    eq(gt.try("next_cell"), false)
    buf(ALIGNED, { 4, 2 })
    eq(gt.try("next_cell"), true)
    vim.wait(50)
    eq(cell_text(), "30")
end)

test("moving the header row is refused", function()
    buf(ROWS, { 2, 2 })
    keys("<A-j>")
    eq(lines(), ROWS)
end)

test("tables need a border at both ends", function()
    buf({ "| a | b |", "+---+---+" }, { 1, 2 })
    eq(gt.in_table(), false)
    buf({ "+---+---+", "| a | b |", "+---+---+" }, { 2, 2 })
    eq(gt.in_table(), true)
end)

test("indented tables keep their indent", function()
    buf({ "  +--+--+", "  | a | bb |", "  +--+--+" }, { 2, 4 })
    gt.call("align")
    eq(lines(), { "  +---+----+", "  | a | bb |", "  +---+----+" })
end)

test("escaped pipes stay in their cell", function()
    buf({ "+-+-+", "| a \\| b | c |", "+-+-+" }, { 2, 2 })
    gt.call("align")
    eq(lines(), { "+--------+---+", "| a \\| b | c |", "+--------+---+" })
end)

test("alignment colons survive realign", function()
    buf({ "+---+---+", "| a | bbbb |", "+:==+==:+", "| 1 | 2 |", "+---+---+" }, { 2, 2 })
    gt.call("align")
    eq(lines()[3], "+:==+=====:+")
end)

test("insert_table with headers", function()
    buf({ "" }, { 1, 0 })
    require("tablamd.convert").insert_table("Uno, Dos")
    vim.cmd.stopinsert()
    eq(lines(), {
        "<!-- prettier-ignore-start -->",
        "",
        "+-----+-----+",
        "| Uno | Dos |",
        "+=====+=====+",
        "|     |     |",
        "+-----+-----+",
        "",
        "<!-- prettier-ignore-end -->",
    })
    eq(cursor(), { 6, 2 })
end)

test("insert_table with a column count", function()
    buf({ "text" }, { 1, 0 })
    require("tablamd.convert").insert_table("2")
    vim.cmd.stopinsert()
    eq(lines()[6], "|     |     |")
    eq(#lines(), 9)
end)

test("insert_table escapes pipes in headers", function()
    buf({ "" }, { 1, 0 })
    require("tablamd.convert").insert_table("a | b, c")
    vim.cmd.stopinsert()
    eq(lines()[4], "| a \\| b | c   |")
    eq(require("tablamd.edit").in_table(), true)
end)

test("tabs in cells are expanded", function()
    buf({ "+-+-+", "| a\tb | c |", "+-+-+" }, { 2, 2 })
    vim.bo.tabstop = 4
    gt.call("align")
    eq(lines()[2], "| a   b | c |")
end)

test("nav keys fall back to the global mapping outside a table", function()
    vim.keymap.set("n", "<A-j>", "<Cmd>let g:fallback = 1<CR>")
    buf({ "plain" }, { 1, 0 })
    keys("<A-j>")
    eq(vim.g.fallback, 1)
    vim.keymap.set("n", "<A-k>", function()
        vim.g.fallback = 2
    end)
    buf({ "plain" }, { 1, 0 })
    keys("<A-k>")
    eq(vim.g.fallback, 2)
end)

-- Header column ----------------------------------------------------------------

local HC_PIPE = {
    "| Name | Mon | Tue |",
    "| ---- | --- | --- |",
    "| Ana  | 3   | 4   |",
    "| Luis | 1   | 2   |",
}
local HC_PIPE_ON = {
    "| Name     | Mon | Tue |",
    "| -------- | --- | --- |",
    "| **Ana**  | 3   | 4   |",
    "| **Luis** | 1   | 2   |",
}

test("toggle_header_col bolds and unbolds the first column's body cells", function()
    buf(HC_PIPE, { 3, 2 })
    gt.call("toggle_header_col")
    eq(lines(), HC_PIPE_ON)
    eq(cell_text(), "Ana**") -- still on the A
    gt.call("toggle_header_col")
    eq(lines(), {
        "| Name | Mon | Tue |",
        "| ---- | --- | --- |",
        "| Ana  | 3   | 4   |",
        "| Luis | 1   | 2   |",
    })
end)

test("toggle_header_col on a grid table keeps list markers outside the bold", function()
    buf({ "+---+---+", "| a | 1 |", "| - b | |", "+---+---+", "| | 2 |", "+---+---+" }, { 2, 2 })
    gt.call("toggle_header_col")
    eq(lines(), {
        "+---------+---+",
        "| **a**   | 1 |",
        "| - **b** |   |",
        "+---------+---+",
        "|         | 2 |",
        "+---------+---+",
    })
end)

test("toggle_header_col with an empty first column does nothing", function()
    buf({ "| a | b |", "| --- | --- |", "|  | 1 |" }, { 3, 2 })
    gt.call("toggle_header_col")
    eq(lines()[3], "|  | 1 |") -- untouched, not even realigned
end)

test("a row typed into a header-column table gets bolded on realign", function()
    buf(HC_PIPE_ON, { 4, 2 })
    gt.call("new_row")
    keys("iPedro<Esc>")
    eq(lines()[5], "| **Pedro** |     |     |")
    eq(cell_text(), "o**") -- still on the last letter typed
end)

test("a half-typed bold cell isn't wrapped again", function()
    buf(HC_PIPE_ON, { 4, 2 })
    gt.call("new_row")
    keys("i**Pe<Esc>")
    eq(lines()[5], "| **Pe     |     |     |")
end)

test("the header column can't be moved, deleted, duplicated or have a column put before it", function()
    buf(HC_PIPE_ON, { 3, 2 })
    gt.call("move_col_right")
    gt.call("delete_col")
    gt.call("insert_col_before")
    gt.call("duplicate_col")
    eq(lines(), HC_PIPE_ON)
    api.nvim_win_set_cursor(0, { 3, 13 }) -- Mon
    gt.call("move_col_left")
    eq(lines(), HC_PIPE_ON)
    gt.call("insert_col_before")
    eq(lines()[1], "| Name     |     | Mon | Tue |")
end)

test("without a header column the first column moves as before", function()
    buf(HC_PIPE, { 3, 2 })
    gt.call("move_col_right")
    eq(lines()[3], "| 3   | Ana  | 4   |")
end)

local HC_GRID = {
    "+----------+-----+",
    "| Name     | Mon |",
    "+==========+=====+",
    "| **Ana**  | 3   |",
    "+----------+-----+",
    "| **Luis** | 1   |",
    "+----------+-----+",
}

test("grid table with a header row and a header column", function()
    buf(HC_GRID, { 4, 4 })
    gt.call("align")
    eq(lines(), HC_GRID) -- the header row's first cell stays plain
    gt.call("delete_col")
    eq(lines(), HC_GRID)
    gt.call("new_row")
    keys("iPedro<Esc>")
    eq(lines()[6], "| **Pedro** |     |") -- right below Ana
end)

test("toggle_header keeps the header column", function()
    buf(HC_GRID, { 2, 2 })
    gt.call("toggle_header") -- the header becomes a body row: its first cell gets bolded
    eq(lines()[2], "| **Name** | Mon |")
    eq(lines()[3], "+----------+-----+")
    gt.call("toggle_header") -- and back: unbolded as the header
    eq(lines(), HC_GRID)
end)

test("sorting ignores the bold markers", function()
    buf({ "| n | x |", "| --- | --- |", "| **10** | a |", "| **9** | b |" }, { 3, 2 })
    gt.call("sort")
    eq({ body_col(1)[3], body_col(1)[4] }, { "**9**", "**10**" })
end)

test("in_table is cheap: only reads the table's lines", function()
    local big = {}
    for i = 1, 20000 do
        big[i] = "line " .. i
    end
    vim.list_extend(big, ALIGNED)
    buf(big, { 20002, 2 })
    local start = vim.uv.hrtime()
    for _ = 1, 200 do
        gt.in_table()
    end
    local ms = (vim.uv.hrtime() - start) / 1e6
    assert(ms < 100, ("200 in_table calls took %.1f ms"):format(ms))
end)

print(("%d passed, %d failed"):format(passed, #failed))
for _, f in ipairs(failed) do
    print("FAIL " .. f)
end
vim.cmd(#failed == 0 and "qa!" or "cq!")
