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
