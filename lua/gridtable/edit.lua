-- Buffer operations on the grid table under the cursor: realign, navigation, row editing.
-- Every operation goes through `run`, which parses the table, lets the operation mutate it,
-- writes it back realigned and puts the cursor on the requested cell.
local core = require("gridtable.core")

local M = {}

local api = vim.api

local function notify(msg, level)
    vim.notify("grid table: " .. msg, level or vim.log.levels.INFO)
end
M.notify = notify

--- Parse the table around lnum. Returns ctx, or nil plus an error for a malformed table.
function M.load(buf, lnum)
    local s, e = core.find_bounds(buf, lnum)
    if not s then
        return nil
    end
    local lines = api.nvim_buf_get_lines(buf, s - 1, e, false)
    local t, err = core.parse(lines)
    if not t then
        return nil, err
    end
    return { buf = buf, s = s, e = e, t = t, old = lines }
end

--- Render ctx.t and write it over the table's old lines (only if something changed).
function M.write(ctx, opts)
    local lines, starts = core.render_all(ctx.t)
    ctx.lines, ctx.starts = lines, starts
    local changed = #lines ~= #ctx.old
    for i = 1, #lines do
        changed = changed or lines[i] ~= ctx.old[i]
    end
    if changed then
        if opts and opts.undojoin then
            pcall(vim.cmd.undojoin)
        end
        api.nvim_buf_set_lines(ctx.buf, ctx.s - 1, ctx.e, false, lines)
        ctx.e = ctx.s + #lines - 1
        ctx.old = lines
    end
    return changed
end

--- Put the cursor at target { i = row index, c = column, off = byte offset }. On a border line
--- `col` (a raw column) wins over `c` (snap to the column's segment).
function M.place(ctx, target)
    local i = math.max(1, math.min(target.i, #ctx.t.rows))
    local r, lnum = ctx.t.rows[i], ctx.s + i - 1
    if r.kind == "row" and target.c then
        local c = math.min(target.c, ctx.t.ncols)
        local col = ctx.starts[i][c] + math.min(target.off or 0, #r.cells[c])
        api.nvim_win_set_cursor(0, { lnum, col })
    elseif target.c and not target.col then
        api.nvim_win_set_cursor(0, { lnum, ctx.starts[i][math.min(target.c, ctx.t.ncols)] })
    else
        api.nvim_win_set_cursor(0, { lnum, math.max(0, math.min(target.col or 0, #ctx.lines[i] - 1)) })
    end
end

--- Run `fn(ctx, pos)` on the table under the cursor, then realign and place the cursor.
--- pos = { i = row index, c = column, off = offset in cell, col = raw column, border = bool }.
--- fn returns the cursor target (default: pos), or false to abort without writing.
--- opts: quiet (no "not in a table" message), undojoin.
function M.run(fn, opts)
    opts = opts or {}
    local buf = api.nvim_get_current_buf()
    local lnum, col = unpack(api.nvim_win_get_cursor(0))
    local ctx, err = M.load(buf, lnum)
    if not ctx then
        if err then
            notify(err, vim.log.levels.WARN)
        elseif not opts.quiet then
            notify("cursor is not inside a grid table")
        end
        return nil
    end
    local line = ctx.old[lnum - ctx.s + 1]
    local c, off = core.cell_at(line, col)
    local pos = { i = lnum - ctx.s + 1, c = c, off = off, col = col, border = core.is_border(line) }
    if not pos.border and c > ctx.t.ncols then -- cursor was on/after the closing pipe
        pos.c, pos.off = ctx.t.ncols, math.huge
    end
    local target = pos
    if fn then
        target = fn(ctx, pos)
        if target == false then
            return nil
        end
        target = target or pos
    end
    M.write(ctx, opts)
    M.place(ctx, target)
    return ctx
end

function M.in_table()
    local lnum = api.nvim_win_get_cursor(0)[1]
    return core.find_bounds(0, lnum) ~= nil
end

function M.align()
    M.run()
end

--- Auto-align for InsertLeave: merged into the previous undo step, warns on a malformed table.
function M.auto_align()
    if vim.b.gridtable_autoalign == false or not core.is_table_line(api.nvim_get_current_line()) then
        return
    end
    M.run(nil, { quiet = true, undojoin = true })
end

--- InsertCharPre: a `|` typed inside a row that already has all its pipes is cell text,
--- so insert it escaped. (Typing a new row by hand still works: it isn't complete yet.)
function M.escape_typed_pipe()
    if vim.v.char ~= "|" or vim.b.gridtable_escape_pipes == false then
        return
    end
    local line = api.nvim_get_current_line()
    local lnum, col = unpack(api.nvim_win_get_cursor(0))
    if not core.is_row(line) or line:sub(col, col) == "\\" then
        return
    end
    local s = core.find_bounds(0, lnum)
    if not s then
        return
    end
    local ncols = core.border_ncols(api.nvim_buf_get_lines(0, s - 1, s, false)[1])
    local _, seps = core.split_row(line)
    -- only between the first and last pipe; outside them it may be a new structural pipe
    if #seps >= ncols + 1 and col > seps[1] and col <= seps[#seps] then
        vim.v.char = "\\|"
    end
end

--- Row index of the next/previous content line from i (skipping borders), or nil.
local function next_row(t, i, step)
    local j = i + step
    while t.rows[j] do
        if t.rows[j].kind == "row" then
            return j
        end
        j = j + step
    end
end

--- Insert an empty row block after block k. Returns the target for its first cell.
local function add_block_after(ctx, k)
    local t = ctx.t
    local borders, blocks = core.split_blocks(t)
    table.insert(blocks, k + 1, { core.new_row(t.ncols) })
    table.insert(borders, k + 2, core.new_border(t.ncols, "-"))
    core.join_blocks(t, borders, blocks)
    return { i = core.row_index(blocks, k + 1, 1), c = 1, off = 0 }
end

function M.next_cell()
    M.run(function(ctx, pos)
        if not pos.border and pos.c < ctx.t.ncols then
            return { i = pos.i, c = pos.c + 1, off = 0 }
        end
        local nxt = next_row(ctx.t, pos.i, 1)
        if nxt then
            return { i = nxt, c = 1, off = 0 }
        end
        return add_block_after(ctx, core.block_of(ctx.t, pos.i))
    end)
end

function M.prev_cell()
    M.run(function(ctx, pos)
        if not pos.border and pos.c > 1 then
            return { i = pos.i, c = pos.c - 1, off = 0 }
        end
        local prv = next_row(ctx.t, pos.i, -1)
        if prv then
            return { i = prv, c = ctx.t.ncols, off = 0 }
        end
    end)
end

local function vertical(step)
    M.run(function(ctx, pos)
        local target = next_row(ctx.t, pos.i, step)
        if target then
            return { i = target, c = pos.c, off = 0 }
        end
    end)
end

function M.cell_down()
    vertical(1)
end

function M.cell_up()
    vertical(-1)
end

--- New empty row below the current row (below the header separator when on the header).
function M.new_row()
    M.run(function(ctx, pos)
        return add_block_after(ctx, core.block_of(ctx.t, pos.i))
    end)
end

--- Continuation line inside the current row (e.g. another bullet in a cell).
function M.new_line()
    M.run(function(ctx, pos)
        if pos.border then
            return false
        end
        table.insert(ctx.t.rows, pos.i + 1, core.new_row(ctx.t.ncols))
        return { i = pos.i + 1, c = pos.c, off = 0 }
    end)
end

-- Columns ---------------------------------------------------------------------

--- Apply fn(list, row) to every row's cells and every border's aligns.
local function each_column_list(t, fn)
    for _, r in ipairs(t.rows) do
        if r.kind == "row" then
            fn(r.cells, "")
        else
            fn(r.aligns, {})
        end
    end
end

local function insert_column(after)
    M.run(function(ctx, pos)
        local at = after and pos.c + 1 or pos.c
        each_column_list(ctx.t, function(list, empty)
            table.insert(list, at, empty)
        end)
        ctx.t.ncols = ctx.t.ncols + 1
        return { i = pos.i, c = at, off = 0 }
    end)
end

--- New empty column to the right of the cursor's column.
function M.insert_col()
    insert_column(true)
end

--- New empty column to the left of the cursor's column.
function M.insert_col_before()
    insert_column(false)
end

function M.delete_col()
    M.run(function(ctx, pos)
        if ctx.t.ncols == 1 then
            notify("can't delete the only column")
            return false
        end
        each_column_list(ctx.t, function(list)
            table.remove(list, pos.c)
        end)
        ctx.t.ncols = ctx.t.ncols - 1
        return { i = pos.i, c = math.min(pos.c, ctx.t.ncols), off = 0 }
    end)
end

local function move_column(step)
    M.run(function(ctx, pos)
        local to = pos.c + step
        if to < 1 or to > ctx.t.ncols then
            return
        end
        each_column_list(ctx.t, function(list)
            list[pos.c], list[to] = list[to], list[pos.c]
        end)
        return { i = pos.i, c = to, off = pos.off }
    end)
end

function M.move_col_left()
    move_column(-1)
end

function M.move_col_right()
    move_column(1)
end

return M
