-- Creating tables: `new_table` from a header spec, `convert` via a pandoc round-trip.
local core = require("gridtable.core")
local edit = require("gridtable.edit")

local M = {}

local api = vim.api

local function config()
    return require("gridtable").config
end

--- Wrap table lines in prettier-ignore markers (conform/prettier would mangle them otherwise).
local function wrap_ignore(out, indent, top, bottom)
    if bottom then
        vim.list_extend(out, { "", indent .. "<!-- prettier-ignore-end -->" })
    end
    if top then
        table.insert(out, 1, "")
        table.insert(out, 1, indent .. "<!-- prettier-ignore-start -->")
    end
    return top and 2 or 0
end

--- Build a new table at the cursor from `spec`:
--- "A, B, C" -> table with that header row; "3" -> headerless table with 3 columns.
function M.insert_table(spec)
    spec = vim.trim(spec or "")
    if spec == "" then
        return
    end
    local headers
    local n = tonumber(spec)
    if n then
        if n < 1 or n ~= math.floor(n) then
            return edit.notify("column count must be a positive integer", vim.log.levels.WARN)
        end
    else
        headers = vim.tbl_map(function(h)
            return core.escape(vim.trim(h))
        end, vim.split(spec, ",", { plain = true }))
        n = #headers
    end
    local indent = api.nvim_get_current_line():match("^(%s*)")
    local t = { indent = indent, ncols = n, rows = { core.new_border(n, "-") } }
    if headers then
        t.rows[#t.rows + 1] = { kind = "row", cells = headers }
        t.rows[#t.rows + 1] = core.new_border(n, "=")
    end
    local body = #t.rows + 1
    t.rows[#t.rows + 1] = core.new_row(n)
    t.rows[#t.rows + 1] = core.new_border(n, "-")
    core.compute_widths(t)
    for c = 1, n do
        t.widths[c] = math.max(3, t.widths[c])
    end
    local out = {}
    for i, r in ipairs(t.rows) do
        out[i] = (core.render(t, r))
    end

    local ignore = config().prettier_ignore
    local top = wrap_ignore(out, indent, ignore, ignore)
    local lnum = api.nvim_win_get_cursor(0)[1]
    local first
    if api.nvim_get_current_line():match("^%s*$") then
        api.nvim_buf_set_lines(0, lnum - 1, lnum, false, out) -- replace blank line
        first = lnum + top
    else
        table.insert(out, 1, "")
        api.nvim_buf_set_lines(0, lnum, lnum, false, out)
        first = lnum + 1 + top
    end
    -- min width 3 is only for the empty table; place the cursor without realigning
    api.nvim_win_set_cursor(0, { first + body - 1, #indent + 2 })
    vim.cmd.startinsert()
end

--- Prompt for headers (or a column count) and insert a new table.
function M.new_table()
    vim.ui.input({ prompt = "Columns (A, B, C — or a number for no header): " }, M.insert_table)
end

--- Is the nearest non-blank line from `from` (walking by `step`) a line containing `marker`?
local function has_marker(buf, from, step, marker)
    local n, i = api.nvim_buf_line_count(buf), from
    while i >= 1 and i <= n do
        local l = api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
        if not l:match("^%s*$") then
            return l:find(marker, 1, true) ~= nil
        end
        i = i + step
    end
    return false
end

--- Run lines s..e (1-based) through pandoc, replacing them with the resulting grid table.
function M.convert_range(s, e)
    -- realign grid tables first: pandoc reads misaligned borders as merged cells
    if core.is_border(api.nvim_buf_get_lines(0, s - 1, s, false)[1]) then
        local ctx = edit.load(0, s)
        if ctx then
            edit.write(ctx)
        end
    end
    local lines = api.nvim_buf_get_lines(0, s - 1, e, false)
    local indent = lines[1]:match("^(%s*)")
    local input = vim.tbl_map(function(l)
        return l:sub(1, #indent) == indent and l:sub(#indent + 1) or l
    end, lines)

    local ok, res = pcall(function()
        return vim.system(config().pandoc, { stdin = table.concat(input, "\n") .. "\n", text = true }):wait()
    end)
    if not ok then
        return edit.notify("could not run pandoc: " .. tostring(res), vim.log.levels.ERROR)
    end
    if res.code ~= 0 then
        return edit.notify("pandoc failed\n" .. (res.stderr or ""), vim.log.levels.ERROR)
    end
    local out = vim.split(vim.trim(res.stdout), "\n", { plain = true })
    if not (core.is_border(out[1]) and core.is_border(out[#out])) then
        return edit.notify("pandoc did not produce a table (is this a table?)", vim.log.levels.WARN)
    end
    for i, l in ipairs(out) do
        out[i] = indent .. l
    end

    local ignore = config().prettier_ignore
    local top = wrap_ignore(
        out,
        indent,
        ignore and not has_marker(0, s - 1, -1, "prettier-ignore-start"),
        ignore and not has_marker(0, e + 1, 1, "prettier-ignore-end")
    )
    api.nvim_buf_set_lines(0, s - 1, e, false, out)

    -- cursor on the first body cell: after the header separator if there is one
    local first = s + top
    local ctx = edit.load(0, first)
    if not ctx then
        return
    end
    edit.write(ctx)
    local borders, blocks = core.split_blocks(ctx.t)
    local k = core.has_header(borders) and 2 or 1
    edit.place(ctx, { i = core.row_index(blocks, k, 1), c = 1, off = 0 })
end

--- Convert the table under the cursor (pipe/simple/grid) to a grid table via pandoc.
--- In visual mode, converts the selected lines. Pandoc may rewrite cell contents and wraps
--- the table to the configured width, unlike `align` which only realigns.
function M.convert()
    local mode = api.nvim_get_mode().mode
    local s, e
    if mode:match("^[vV\22]") then
        s, e = vim.fn.line("v"), vim.fn.line(".")
        if s > e then
            s, e = e, s
        end
        vim.cmd("normal! \27")
    else
        local lnum = api.nvim_win_get_cursor(0)[1]
        local function get(l)
            return api.nvim_buf_get_lines(0, l - 1, l, false)[1]
        end
        local cur = get(lnum)
        if cur:match("^%s*$") then
            return edit.notify("cursor is not on a table")
        end
        -- contiguous table-looking lines (grid/pipe), else the paragraph (simple tables)
        local same = core.is_table_line(cur) and core.is_table_line
            or function(l)
                return not l:match("^%s*$")
            end
        local n = api.nvim_buf_line_count(0)
        s, e = lnum, lnum
        while s > 1 and same(get(s - 1)) do
            s = s - 1
        end
        while e < n and same(get(e + 1)) do
            e = e + 1
        end
    end
    M.convert_range(s, e)
end

return M
