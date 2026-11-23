-- Buffer operations on the grid table under the cursor: realign, navigation, row editing.
-- Every operation goes through `run`, which parses the table, lets the operation mutate it,
-- writes it back realigned and puts the cursor on the requested cell.
local core = require("tablamd.core")
local headcol = require("tablamd.headcol")

local M = {}

local api = vim.api

local function notify(msg, level)
    vim.notify("tablamd: " .. msg, level or vim.log.levels.INFO)
end
M.notify = notify

--- Parse the table around lnum. Returns ctx, or nil plus an error for a malformed table.
function M.load(buf, lnum)
    local s, e, format = core.find_table(buf, lnum)
    if not s then
        return nil
    end
    local lines = api.nvim_buf_get_lines(buf, s - 1, e, false)
    local t, err = core.parse(lines, vim.bo[buf].tabstop, format)
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
    local t = ctx.t
    local i = math.max(1, math.min(target.i, #t.rows))
    -- an undrawn pipe-table border: use the line above it
    while not t.lnum[i] and i > 1 do
        i = i - 1
    end
    local r, l = t.rows[i], t.lnum[i] or 1
    local lnum = ctx.s + l - 1
    if r.kind == "row" and target.c then
        local c = math.min(target.c, ctx.t.ncols)
        local col = ctx.starts[i][c] + math.min(target.off or 0, #r.cells[c])
        api.nvim_win_set_cursor(0, { lnum, col })
    elseif target.c and not target.col then
        api.nvim_win_set_cursor(0, { lnum, ctx.starts[i][math.min(target.c, ctx.t.ncols)] })
    else
        api.nvim_win_set_cursor(0, { lnum, math.max(0, math.min(target.col or 0, #ctx.lines[l] - 1)) })
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
            notify("cursor is not inside a table")
        end
        return nil
    end
    local line = ctx.old[lnum - ctx.s + 1]
    local i = ctx.t.index[lnum - ctx.s + 1]
    local border = ctx.t.rows[i].kind == "border"
    local c, off
    if ctx.t.format == "pipe" then
        c, off = require("tablamd.pipe").cell_at(line, col)
    else
        c, off = core.cell_at(line, col)
    end
    if border then
        off = 0
    end
    local pos = { i = i, c = c, off = off, col = col, border = border }
    if c > ctx.t.ncols then -- cursor was on/after the closing pipe
        pos.c, pos.off = ctx.t.ncols, border and 0 or math.huge
    end
    -- a row typed into a table with a header column gets its first cell bolded too
    local follow = headcol.follow(ctx.t, (core.block_of(ctx.t, i)))
    if pos.c == 1 and follow[ctx.t.rows[i]] and pos.off ~= math.huge then
        pos.off = pos.off + 2
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
    return core.find_table(0, lnum) ~= nil
end

--- For actions that need multi-line rows or an optional header: refuse on pipe tables.
local function grid_only(ctx, what)
    if ctx.t.format == "pipe" then
        notify(what .. " needs a grid table (pipe table rows are single lines; \\tc converts)")
        return false
    end
    return true
end

function M.align()
    M.run()
end

--- Auto-align for InsertLeave: merged into the previous undo step, warns on a malformed table.
function M.auto_align()
    local line = api.nvim_get_current_line()
    if vim.b.tablamd_autoalign == false or not (line:find("|", 1, true) or core.is_border(line)) then
        return
    end
    M.run(nil, { quiet = true, undojoin = true })
end

--- InsertCharPre: a `|` typed inside a row that already has all its pipes is cell text,
--- so insert it escaped. (Typing a new row by hand still works: it isn't complete yet.)
function M.escape_typed_pipe()
    if vim.v.char ~= "|" or vim.b.tablamd_escape_pipes == false then
        return
    end
    local line = api.nvim_get_current_line()
    local lnum, col = unpack(api.nvim_win_get_cursor(0))
    if not core.is_row(line) or line:sub(col, col) == "\\" then
        return
    end
    local s, _, format = core.find_table(0, lnum)
    if not s then
        return
    end
    local ncols
    if format == "pipe" then
        ncols = #require("tablamd.pipe").split(api.nvim_buf_get_lines(0, s, s + 1, false)[1])
    else
        ncols = core.border_ncols(api.nvim_buf_get_lines(0, s - 1, s, false)[1])
    end
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

--- Index of the row (block) the cursor is in. On a border: the row above it (0 on the top).
local function current_block(t, pos)
    local k = 0
    for j = 1, pos.i do
        if t.rows[j].kind == "border" then
            k = k + 1
        end
    end
    return pos.border and k - 1 or k
end

--- Next cell along the row's first line; after the last one, the first cell of the next row
--- (a multi-line row counts once). On the last cell of the table, adds a row.
function M.next_cell()
    M.run(function(ctx, pos)
        local t = ctx.t
        if not pos.border and pos.c < t.ncols then
            return { i = pos.i, c = pos.c + 1, off = 0 }
        end
        local _, blocks = core.split_blocks(t)
        local to = current_block(t, pos) + 1
        if to <= #blocks then
            return { i = core.row_index(blocks, to, 1), c = 1, off = 0 }
        end
        return add_block_after(ctx, #blocks)
    end)
end

--- Reverse of next_cell: before the first cell, the last cell of the previous row's first line.
function M.prev_cell()
    M.run(function(ctx, pos)
        local t = ctx.t
        if not pos.border and pos.c > 1 then
            return { i = pos.i, c = pos.c - 1, off = 0 }
        end
        local _, blocks = core.split_blocks(t)
        local k = current_block(t, pos)
        -- from a continuation line, or from a border, the previous stop is row k's first line
        local _, o = core.block_of(t, pos.i)
        local to = (pos.border or o > 1) and k or k - 1
        if to >= 1 then
            return { i = core.row_index(blocks, to, 1), c = t.ncols, off = 0 }
        end
    end)
end

--- Same column, first line of the next/previous row (a multi-line row counts once; use
--- j/k inside it). Going down from the last row adds a row.
local function vertical(step)
    M.run(function(ctx, pos)
        local t = ctx.t
        local _, blocks = core.split_blocks(t)
        local k = current_block(t, pos)
        -- from a border, down is the row below it (k + 1) and up the row above it (k)
        local to = (pos.border and step < 0) and k or k + step
        if to >= 1 and to <= #blocks then
            return { i = core.row_index(blocks, to, 1), c = pos.c, off = 0 }
        end
        if step > 0 then
            local new = add_block_after(ctx, #blocks)
            new.c = pos.c
            return new
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
        if pos.border or not grid_only(ctx, "a line inside a row") then
            return false
        end
        table.insert(ctx.t.rows, pos.i + 1, core.new_row(ctx.t.ncols))
        return { i = pos.i + 1, c = pos.c, off = 0 }
    end)
end

-- Columns ---------------------------------------------------------------------

--- A header column stays the first column: refuse (with a message) when `cond` holds.
local function protect_header_col(ctx, cond, msg)
    if cond and headcol.active(ctx.t) then
        notify(msg .. " (\\tH turns it off)")
        return true
    end
    return false
end

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
        if protect_header_col(ctx, at == 1, "can't insert a column before the header column") then
            return false
        end
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

--- Delete `count` columns starting at the cursor's. Always leaves one column.
function M.delete_col(count)
    count = count or 1
    M.run(function(ctx, pos)
        if protect_header_col(ctx, pos.c == 1, "can't delete the header column") then
            return false
        end
        local n = math.min(count, ctx.t.ncols - pos.c + 1, ctx.t.ncols - 1)
        if n < 1 then
            notify("can't delete the only column")
            return false
        end
        each_column_list(ctx.t, function(list)
            for _ = 1, n do
                table.remove(list, pos.c)
            end
        end)
        ctx.t.ncols = ctx.t.ncols - n
        return { i = pos.i, c = math.min(pos.c, ctx.t.ncols), off = 0 }
    end)
end

--- Move the cursor's column `count` places left (step -1) or right (1), clamped.
local function move_column(step, count)
    count = count or 1
    M.run(function(ctx, pos)
        if protect_header_col(ctx, pos.c == 1, "can't move the header column") then
            return false
        end
        local min = headcol.active(ctx.t) and 2 or 1
        local to = math.max(min, math.min(ctx.t.ncols, pos.c + step * count))
        if to == pos.c then
            return
        end
        each_column_list(ctx.t, function(list)
            table.insert(list, to, table.remove(list, pos.c))
        end)
        return { i = pos.i, c = to, off = pos.off }
    end)
end

function M.move_col_left(count)
    move_column(-1, count)
end

function M.move_col_right(count)
    move_column(1, count)
end

-- Rows (a row = a block of lines between two borders) -----------------------

--- Delete `count` rows starting at the current one and yank them (each with a border below,
--- so `p` on a border line pastes them back as valid rows). Always leaves one body row.
function M.delete_row(count)
    count = count or 1
    M.run(function(ctx, pos)
        local t = ctx.t
        local borders, blocks = core.split_blocks(t)
        local k = core.block_of(t, pos.i)
        local header = core.has_header(borders)
        -- deleting the header (k == 1) makes the table headerless, so any row may remain;
        -- otherwise the header stays and needs a body row under it
        if k == 1 and ctx.t.format == "pipe" then
            notify("a pipe table needs its header row")
            return false
        end
        local keep = (header and k > 1) and 2 or 1
        local n = math.min(count, #blocks - k + 1, #blocks - keep)
        if n < 1 then
            notify("can't delete the only body row")
            return false
        end
        core.compute_widths(t)
        local yank = {}
        for b = k, k + n - 1 do
            for _, r in ipairs(blocks[b]) do
                yank[#yank + 1] = (core.render(t, r))
            end
            if t.format ~= "pipe" then
                yank[#yank + 1] = (core.render(t, core.new_border(t.ncols, "-")))
            end
        end
        vim.fn.setreg(vim.v.register, yank, "l")

        if header and k == 1 then
            -- the table becomes headerless: alignment moves to the top border
            borders[1].aligns = borders[2].aligns
        end
        -- drop each deleted row's border below it, or above it when deleting the last rows
        local first_border = (k + n - 1 < #blocks) and k + 1 or k
        for _ = 1, n do
            table.remove(borders, first_border)
            table.remove(blocks, k)
        end
        core.join_blocks(t, borders, blocks)
        k = math.min(k, #blocks)
        return { i = core.row_index(blocks, k, 1), c = pos.c, off = 0 }
    end)
end

--- Move the current row `count` rows down (step 1) or up (-1), clamped to the body.
local function move_row(step, count)
    count = count or 1
    M.run(function(ctx, pos)
        local t = ctx.t
        local borders, blocks = core.split_blocks(t)
        local k, o = core.block_of(t, pos.i)
        local first = core.has_header(borders) and 2 or 1
        if pos.border then
            return
        end
        if k < first then
            notify("can't move the header row")
            return false
        end
        local to = math.max(first, math.min(#blocks, k + step * count))
        if to == k then
            return
        end
        table.insert(blocks, to, table.remove(blocks, k))
        core.join_blocks(t, borders, blocks)
        return { i = core.row_index(blocks, to, o), c = pos.c, off = pos.off }
    end)
end

function M.move_row_down(count)
    move_row(1, count)
end

function M.move_row_up(count)
    move_row(-1, count)
end

-- Alignment -------------------------------------------------------------------

local ALIGN_CYCLE = { default = "left", left = "center", center = "right", right = "default" }
local ALIGN_FLAGS = {
    default = {},
    left = { left = true },
    center = { left = true, right = true },
    right = { right = true },
}

local function align_name(a)
    if a.left and a.right then
        return "center"
    end
    return a.left and "left" or a.right and "right" or "default"
end

--- Cycle the column's alignment: default -> left -> center -> right. Pandoc reads it from
--- the header separator, or from the top border in a headerless table.
function M.cycle_align()
    M.run(function(ctx, pos)
        local borders = core.split_blocks(ctx.t)
        local b = core.has_header(borders) and borders[2] or borders[1]
        local name = ALIGN_CYCLE[align_name(b.aligns[pos.c])]
        b.aligns[pos.c] = vim.deepcopy(ALIGN_FLAGS[name])
        api.nvim_echo({ { ("column %d: %s"):format(pos.c, name) } }, false, {})
    end)
end

--- Make the first row the header (`=` separator below it), or turn the header into a
--- normal row. Alignment moves between the separator and the top border with it. A header
--- column stays one: the row's first cell is unbolded as a header, bolded as a body row.
function M.toggle_header()
    M.run(function(ctx, pos)
        if not grid_only(ctx, "toggling the header") then
            return false
        end
        local borders, blocks = core.split_blocks(ctx.t)
        if #blocks < 2 then
            notify("a header needs at least one row below it")
            return false
        end
        local header_col = headcol.active(ctx.t)
        local top, sep = borders[1], borders[2]
        local from, to = top, sep
        if sep.fill == "=" then
            sep.fill, from, to = "-", sep, top
        else
            sep.fill = "="
        end
        local has = function(b)
            for _, a in ipairs(b.aligns) do
                if a.left or a.right then
                    return true
                end
            end
        end
        if has(from) and not has(to) then
            from.aligns, to.aligns = to.aligns, from.aligns
        end
        if header_col then
            local now_header = sep.fill == "="
            for _, r in ipairs(blocks[1]) do
                local cell, new = r.cells[1], nil
                if now_header and headcol.is_bold(cell) then
                    new = headcol.unbold(cell)
                elseif not now_header and cell:match("%S") and not headcol.is_bold(cell) then
                    new = headcol.bold(cell)
                end
                if new then
                    r.cells[1] = new
                    if r == ctx.t.rows[pos.i] and pos.c == 1 and pos.off ~= math.huge then
                        pos.off = math.max(0, pos.off + (now_header and -2 or 2))
                    end
                end
            end
        end
    end)
end

--- Make the first column a header column (its body cells bold, so the PDF shows them as row
--- labels, and protected from column moves and deletes), or a normal column again.
function M.toggle_header_col()
    M.run(function(ctx, pos)
        local on, changed = headcol.toggle(ctx.t)
        if on and next(changed) == nil then
            notify("the first column has no text to make a header column")
            return false
        end
        api.nvim_echo({ { on and "header column on" or "header column off" } }, false, {})
        if pos.c == 1 and changed[ctx.t.rows[pos.i]] and pos.off ~= math.huge then
            pos.off = math.max(0, pos.off + (on and 2 or -2))
        end
    end)
end

-- Sorting ---------------------------------------------------------------------

-- fold accents so "Álvaro" sorts with the a's; ñ goes right after n
local FOLD = {
    ["á"] = "a",
    ["é"] = "e",
    ["í"] = "i",
    ["ó"] = "o",
    ["ú"] = "u",
    ["ü"] = "u",
    ["Á"] = "a",
    ["É"] = "e",
    ["Í"] = "i",
    ["Ó"] = "o",
    ["Ú"] = "u",
    ["Ü"] = "u",
    ["à"] = "a",
    ["è"] = "e",
    ["ì"] = "i",
    ["ò"] = "o",
    ["ù"] = "u",
    ["ç"] = "c",
    ["ñ"] = "n~",
    ["Ñ"] = "n~",
}

local function sort_key(block, c)
    local parts = {}
    for _, r in ipairs(block) do
        if r.cells[c] ~= "" then
            parts[#parts + 1] = vim.trim(headcol.strip(r.cells[c]))
        end
    end
    local text = table.concat(parts, " ")
    return {
        empty = text == "",
        num = tonumber((text:gsub("^%$", ""))),
        str = text:gsub("[\195][\128-\191]", FOLD):lower(),
    }
end

--- Empty cells last, numbers before text and compared numerically.
local function key_less(a, b)
    if a.empty ~= b.empty then
        return b.empty
    end
    if (a.num ~= nil) ~= (b.num ~= nil) then
        return a.num ~= nil
    end
    if a.num and a.num ~= b.num then
        return a.num < b.num
    end
    return a.str < b.str
end

--- Sort the body rows by the cursor's column (stable). The cursor stays on its row.
local function sort_rows(desc)
    M.run(function(ctx, pos)
        local t = ctx.t
        local borders, blocks = core.split_blocks(t)
        local first = core.has_header(borders) and 2 or 1
        local k, o = core.block_of(t, pos.i)
        local items = {}
        for b = first, #blocks do
            items[#items + 1] = { block = blocks[b], key = sort_key(blocks[b], pos.c), idx = b }
        end
        table.sort(items, function(x, y)
            if key_less(x.key, y.key) then
                return not desc
            elseif key_less(y.key, x.key) then
                return desc
            end
            return x.idx < y.idx
        end)
        local cur = k
        for n, it in ipairs(items) do
            blocks[first + n - 1] = it.block
            if it.idx == cur then
                k = first + n - 1
            end
        end
        -- sorted rows are plain body rows: keep borders as they were
        core.join_blocks(t, borders, blocks)
        return { i = core.row_index(blocks, k, math.max(o, 1)), c = pos.c, off = 0 }
    end)
end

function M.sort()
    sort_rows(false)
end

function M.sort_desc()
    sort_rows(true)
end

-- Joining / splitting multi-line rows -------------------------------------------

--- Join the current row's lines into one line (each column's text joined with spaces).
function M.join_row()
    M.run(function(ctx, pos)
        if not grid_only(ctx, "joining a row") then
            return false
        end
        local t = ctx.t
        local borders, blocks = core.split_blocks(t)
        local k = core.block_of(t, pos.i)
        local row = core.new_row(t.ncols)
        for c = 1, t.ncols do
            local parts = {}
            for _, r in ipairs(blocks[k]) do
                if r.cells[c] ~= "" then
                    parts[#parts + 1] = vim.trim(r.cells[c])
                end
            end
            row.cells[c] = table.concat(parts, " ")
        end
        blocks[k] = { row }
        core.join_blocks(t, borders, blocks)
        return { i = core.row_index(blocks, k, 1), c = pos.c, off = 0 }
    end)
end

--- Split the current row: each of its lines becomes a row of its own.
function M.break_row()
    M.run(function(ctx, pos)
        if not grid_only(ctx, "breaking up a row") then
            return false
        end
        local t = ctx.t
        local borders, blocks = core.split_blocks(t)
        local k, o = core.block_of(t, pos.i)
        if #blocks[k] < 2 then
            return
        end
        if k == 1 and core.has_header(borders) then
            notify("can't split the header row")
            return false
        end
        local lines = table.remove(blocks, k)
        for n, r in ipairs(lines) do
            table.insert(blocks, k + n - 1, { r })
            if n > 1 then
                table.insert(borders, k + n - 1, core.new_border(t.ncols, "-"))
            end
        end
        core.join_blocks(t, borders, blocks)
        return { i = core.row_index(blocks, k + math.max(o, 1) - 1, 1), c = pos.c, off = pos.off }
    end)
end

return M
