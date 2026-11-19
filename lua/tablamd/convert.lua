-- Creating and converting tables: `new_table` from a header spec, `convert` toggles grid <-> pipe,
-- `pandoc` round-trips through pandoc (any table -> grid, wrapping long cells).
local core = require("tablamd.core")
local edit = require("tablamd.edit")

local M = {}

local api = vim.api

local function config()
    return require("tablamd").config
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
--- "A, B, C" -> table with that header row; "3" -> 3 columns, headerless for a grid table and
--- with an empty header row for a pipe table (which always has one).
--- `format` is "grid" (default) or "pipe".
function M.insert_table(spec, format)
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
    local pipe = format == "pipe"
    local indent = api.nvim_get_current_line():match("^(%s*)")
    local t = { format = pipe and "pipe" or "grid", indent = indent, ncols = n, rows = { core.new_border(n, "-") } }
    if headers or pipe then
        t.rows[#t.rows + 1] = headers and { kind = "row", cells = headers } or core.new_row(n)
        local sep = core.new_border(n, "=")
        sep.sep = pipe or nil
        t.rows[#t.rows + 1] = sep
    end
    local body = #t.rows + 1
    t.rows[#t.rows + 1] = core.new_row(n)
    t.rows[#t.rows + 1] = core.new_border(n, "-")
    core.compute_widths(t)
    -- empty grid columns would be 1 wide; keep them at 3 until the first realign
    for c = 1, n do
        t.widths[c] = math.max(3, t.widths[c])
    end
    local out, starts = {}, {}
    for i, r in ipairs(t.rows) do
        local l
        l, starts[i] = core.render(t, r)
        out[#out + 1] = l
    end
    core.index_lines(t)

    -- pipe tables are formatted by prettier itself; grid tables must be hidden from it
    local ignore = config().prettier_ignore and not pipe
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
    api.nvim_win_set_cursor(0, { first + t.lnum[body] - 1, starts[body][1] })
    vim.cmd.startinsert()
end

local last_format = "pipe"

--- Prompt for headers (or a column count) and insert a new table in the configured format
--- (`new_table_format`: "grid", "pipe" or "ask").
function M.new_table()
    local function input(format)
        vim.ui.input({ prompt = "Columns (A, B, C — or a number): " }, function(spec)
            M.insert_table(spec, format)
        end)
    end
    local format = config().new_table_format
    if format ~= "ask" then
        return input(format)
    end
    local choices = last_format == "pipe" and { "pipe", "grid" } or { "grid", "pipe" }
    vim.ui.select(choices, { prompt = "Table format" }, function(choice)
        if choice then
            last_format = choice
            input(choice)
        end
    end)
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
function M.pandoc()
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

--- Delete the prettier-ignore markers (and the blank lines up to them) right around lines
--- s..e. Returns the table's new first line.
local function remove_markers(s, e)
    local function find(from, step, marker)
        local i, n = from, api.nvim_buf_line_count(0)
        while i >= 1 and i <= n do
            local l = api.nvim_buf_get_lines(0, i - 1, i, false)[1]
            if not l:match("^%s*$") then
                return l:find(marker, 1, true) and i or nil
            end
            i = i + step
        end
    end
    local bottom = find(e + 1, 1, "prettier-ignore-end")
    local top = find(s - 1, -1, "prettier-ignore-start")
    if bottom and top then
        api.nvim_buf_set_lines(0, e, bottom, false, {})
        api.nvim_buf_set_lines(0, top - 1, s - 1, false, {})
        return top
    end
    return s
end

--- Add prettier-ignore markers around lines s..e unless they're there. Returns the new s.
local function add_markers(s, e, indent)
    if not has_marker(0, e + 1, 1, "prettier-ignore-end") then
        api.nvim_buf_set_lines(0, e, e, false, { "", indent .. "<!-- prettier-ignore-end -->" })
    end
    if not has_marker(0, s - 1, -1, "prettier-ignore-start") then
        api.nvim_buf_set_lines(0, s - 1, s - 1, false, { indent .. "<!-- prettier-ignore-start -->", "" })
        return s + 2
    end
    return s
end

--- Toggle the table under the cursor between grid and pipe format, keeping cell text as is.
--- Anything else (a simple table, or a visual selection) goes through pandoc instead.
function M.convert()
    if api.nvim_get_mode().mode:match("^[vV\22]") then
        return M.pandoc()
    end
    local s, _, format = core.find_table(0, api.nvim_win_get_cursor(0)[1])
    if not s then
        return M.pandoc()
    end
    local to = format == "grid" and "pipe" or "grid"
    local ctx = edit.run(function(ctx, pos)
        local t = ctx.t
        local borders, blocks = core.split_blocks(t)
        if to == "pipe" then
            if not core.has_header(borders) then
                edit.notify("a pipe table needs a header row (add one with \\th)")
                return false
            end
            for k, b in ipairs(blocks) do
                if #b > 1 then
                    edit.notify(("row %d spans %d lines; pipe table rows are single lines (\\tj joins)"):format(k, #b))
                    return false
                end
            end
            for _, r in ipairs(t.rows) do
                if r.kind == "row" then
                    r.cells = vim.tbl_map(vim.trim, r.cells)
                end
            end
            borders[2].sep = true
        else
            borders[2].sep = nil
        end
        t.format = to
        return { i = pos.i, c = pos.c, off = 0 }
    end)
    if not ctx then
        return
    end
    local cur = api.nvim_win_get_cursor(0)
    local rel = cur[1] - ctx.s
    local first = ctx.s
    if to == "pipe" then
        first = remove_markers(ctx.s, ctx.e)
    elseif config().prettier_ignore then
        first = add_markers(ctx.s, ctx.e, ctx.t.indent)
    end
    api.nvim_win_set_cursor(0, { first + rel, cur[2] })
end

return M
