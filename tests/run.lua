-- Headless test runner: `make test`
-- nvim --headless -u NONE -i NONE --cmd "set rtp^=." -l tests/run.lua
vim.g.maplocalleader = "\\"
vim.o.swapfile = false
vim.o.undolevels = 1000
vim.cmd("filetype on")

local gt = require("gridtable")
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

test("auto-align honours b:gridtable_autoalign = false", function()
    buf(ALIGNED, { 4, 2 })
    vim.b.gridtable_autoalign = false
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
    require("gridtable.convert").insert_table("Uno, Dos")
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
    require("gridtable.convert").insert_table("2")
    vim.cmd.stopinsert()
    eq(lines()[6], "|     |     |")
    eq(#lines(), 9)
end)

test("insert_table escapes pipes in headers", function()
    buf({ "" }, { 1, 0 })
    require("gridtable.convert").insert_table("a | b, c")
    vim.cmd.stopinsert()
    eq(lines()[4], "| a \\| b | c   |")
    eq(require("gridtable.edit").in_table(), true)
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
