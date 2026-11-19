-- Pandoc grid table helpers: realign, cell navigation, row insertion.
-- Pure Lua (no pandoc round-trip), so cell contents are kept verbatim.
-- Limitations: no row/column spans; a literal `|` inside a cell must be written `\|`.
local M = {}

local api = vim.api

local function is_border(l)
    return l:match("^%s*%+[-=:+]*%+%s*$") ~= nil and l:find("[-=]") ~= nil
end

local function is_row(l)
    return l:match("^%s*|") ~= nil
end

local function is_table_line(l)
    return is_border(l) or is_row(l)
end

--- Split a row on unescaped `|`. Returns cells and 0-based byte offsets of each separator.
local function split_row(s)
    local cells, seps, cur = {}, {}, {}
    local i = 1
    while i <= #s do
        local ch = s:sub(i, i)
        if ch == "\\" then
            cur[#cur + 1] = s:sub(i, i + 1)
            i = i + 2
        else
            if ch == "|" then
                seps[#seps + 1] = i - 1
                cells[#cells + 1] = table.concat(cur)
                cur = {}
            else
                cur[#cur + 1] = ch
            end
            i = i + 1
        end
    end
    cells[#cells + 1] = table.concat(cur)
    -- cells[1] is whatever precedes the leading `|` (only indent)
    table.remove(cells, 1)
    -- drop the piece after the closing `|`
    if #cells > 0 and cells[#cells]:match("^%s*$") and #seps > 1 then
        cells[#cells] = nil
    end
    return cells, seps
end

--- Strip exactly one leading pad space and trailing whitespace, keeping inner indentation.
local function norm_cell(c)
    return (c:gsub("^ ", ""):gsub("%s+$", ""))
end

--- Find table bounds (1-based, inclusive) around lnum. Must start and end with a border.
local function find_bounds(lines, lnum)
    if not lines[lnum] or not is_table_line(lines[lnum]) then
        return nil
    end
    local s, e = lnum, lnum
    while s > 1 and is_table_line(lines[s - 1]) do
        s = s - 1
    end
    while e < #lines and is_table_line(lines[e + 1]) do
        e = e + 1
    end
    if not (is_border(lines[s]) and is_border(lines[e])) then
        return nil
    end
    return s, e
end

local function parse(tlines)
    local indent = tlines[1]:match("^(%s*)")
    local _, plus = vim.trim(tlines[1]):gsub("%+", "")
    local ncols = plus - 1
    local rows = {}
    for i, l in ipairs(tlines) do
        if is_border(l) then
            local segs = vim.split(vim.trim(l):sub(2, -2), "+", { plain = true })
            if #segs ~= ncols then
                return nil, ("line %d: border has %d columns, expected %d (spans unsupported)"):format(i, #segs, ncols)
            end
            local aligns = {}
            for c, seg in ipairs(segs) do
                aligns[c] = { left = seg:sub(1, 1) == ":", right = #seg > 1 and seg:sub(-1) == ":" }
            end
            rows[i] = { kind = "border", fill = l:find("=") and "=" or "-", aligns = aligns }
        else
            local raw = split_row(l)
            if #raw > ncols then
                return nil, ("line %d: %d cells but %d columns (write a literal pipe as \\|)"):format(i, #raw, ncols)
            end
            local cells = {}
            for c = 1, ncols do
                cells[c] = norm_cell(raw[c] or "")
            end
            rows[i] = { kind = "row", cells = cells }
        end
    end
    local widths = {}
    for c = 1, ncols do
        widths[c] = 1
    end
    for _, r in ipairs(rows) do
        if r.kind == "row" then
            for c, cell in ipairs(r.cells) do
                widths[c] = math.max(widths[c], vim.fn.strdisplaywidth(cell))
            end
        end
    end
    return { indent = indent, ncols = ncols, rows = rows, widths = widths }
end

--- Render one row; returns the line and 0-based byte offsets where each cell's content starts.
local function render(t, r)
    if r.kind == "border" then
        local segs = {}
        for c, w in ipairs(t.widths) do
            local seg = r.fill:rep(w + 2)
            local a = r.aligns and r.aligns[c] or {}
            if a.left then
                seg = ":" .. seg:sub(2)
            end
            if a.right then
                seg = seg:sub(1, -2) .. ":"
            end
            segs[c] = seg
        end
        return t.indent .. "+" .. table.concat(segs, "+") .. "+", {}
    end
    local out, starts = { t.indent, "|" }, {}
    local len = #t.indent + 1
    for c, w in ipairs(t.widths) do
        local cell = r.cells[c]
        starts[c] = len + 1
        local piece = " " .. cell .. (" "):rep(w - vim.fn.strdisplaywidth(cell)) .. " |"
        out[#out + 1] = piece
        len = len + #piece
    end
    return table.concat(out), starts
end

--- Which cell (index, byte offset into its content) the 0-based col falls in, for a row line.
local function cell_at(line, col)
    local _, seps = split_row(line)
    local c = 1
    for k = 1, #seps do
        if seps[k] <= col then
            c = k
        end
    end
    local start = seps[c] + 1
    if line:sub(start + 1, start + 1) == " " then
        start = start + 1
    end
    return c, math.max(0, col - start)
end

--- Realign the table containing lnum. Returns a context table, or nil if not in a valid table.
local function align_at(buf, lnum, quiet)
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local s, e = find_bounds(lines, lnum)
    if not s then
        return nil
    end
    local t, err = parse(vim.list_slice(lines, s, e))
    if not t then
        if not quiet then
            vim.notify("grid table: " .. err, vim.log.levels.WARN)
        end
        return nil
    end
    local new, starts, changed = {}, {}, false
    for i, r in ipairs(t.rows) do
        new[i], starts[i] = render(t, r)
        if new[i] ~= lines[s + i - 1] then
            changed = true
        end
    end
    if changed then
        api.nvim_buf_set_lines(buf, s - 1, e, false, new)
    end
    return { s = s, e = e, t = t, lines = new, starts = starts }
end

local function set_cell_cursor(ctx, lnum, c, offset)
    local i = lnum - ctx.s + 1
    local cell = ctx.t.rows[i].cells[c]
    api.nvim_win_set_cursor(0, { lnum, ctx.starts[i][c] + math.min(offset or 0, #cell) })
end

--- Realign keeping the cursor in the same cell. Returns ctx and the cursor's cell index.
local function align_keep_cursor(quiet)
    local buf = api.nvim_get_current_buf()
    local lnum, col = unpack(api.nvim_win_get_cursor(0))
    local line = api.nvim_get_current_line()
    local c, off
    if is_row(line) then
        c, off = cell_at(line, col)
    end
    local ctx = align_at(buf, lnum, quiet)
    if not ctx then
        return nil
    end
    if c then
        if c > ctx.t.ncols then -- cursor was on/after the closing pipe
            c, off = ctx.t.ncols, math.huge
        end
        set_cell_cursor(ctx, lnum, c, off)
    else
        api.nvim_win_set_cursor(0, { lnum, math.min(col, #ctx.lines[lnum - ctx.s + 1]) })
    end
    return ctx, c
end

function M.align()
    if not align_keep_cursor(false) then
        vim.notify("grid table: cursor is not inside a grid table", vim.log.levels.INFO)
    end
end

--- Auto-align for InsertLeave: silent, merged into the previous undo step.
function M.auto_align()
    if vim.b.gridtable_autoalign == false or not is_table_line(api.nvim_get_current_line()) then
        return
    end
    local lnum = api.nvim_win_get_cursor(0)[1]
    local lines = api.nvim_buf_get_lines(0, 0, -1, false)
    local s, e = find_bounds(lines, lnum)
    if not s then
        return
    end
    local t = parse(vim.list_slice(lines, s, e))
    if not t then
        return
    end
    for i, r in ipairs(t.rows) do
        if render(t, r) ~= lines[s + i - 1] then
            pcall(vim.cmd.undojoin)
            align_keep_cursor(true)
            return
        end
    end
end

local function row_lines(ctx, from, to, step)
    for l = from, to, step do
        if ctx.t.rows[l - ctx.s + 1].kind == "row" then
            return l
        end
    end
end

function M.next_cell()
    local ctx, c = align_keep_cursor(false)
    if not ctx then
        return
    end
    local lnum = api.nvim_win_get_cursor(0)[1]
    if c and c < ctx.t.ncols then
        return set_cell_cursor(ctx, lnum, c + 1, 0)
    end
    local nxt = row_lines(ctx, lnum + 1, ctx.e, 1)
    if nxt then
        return set_cell_cursor(ctx, nxt, 1, 0)
    end
    M.new_row()
end

function M.prev_cell()
    local ctx, c = align_keep_cursor(false)
    if not ctx then
        return
    end
    local lnum = api.nvim_win_get_cursor(0)[1]
    if c and c > 1 then
        return set_cell_cursor(ctx, lnum, c - 1, 0)
    end
    local prv = row_lines(ctx, lnum - 1, ctx.s, -1)
    if prv then
        set_cell_cursor(ctx, prv, ctx.t.ncols, 0)
    end
end

local function empty_row(ctx)
    local cells = {}
    for c = 1, ctx.t.ncols do
        cells[c] = ""
    end
    return (render(ctx.t, { kind = "row", cells = cells }))
end

--- Is the cursor inside a valid grid table? (cheap line check first)
function M.in_table()
    if not is_table_line(api.nvim_get_current_line()) then
        return false
    end
    local lines = api.nvim_buf_get_lines(0, 0, -1, false)
    return find_bounds(lines, api.nvim_win_get_cursor(0)[1]) ~= nil
end

--- Same column, next/previous content line (skipping borders).
local function vertical(step)
    local ctx, c = align_keep_cursor(false)
    if not ctx then
        return
    end
    local lnum = api.nvim_win_get_cursor(0)[1]
    local target = row_lines(ctx, lnum + step, step > 0 and ctx.e or ctx.s, step)
    if target then
        set_cell_cursor(ctx, target, math.min(c or 1, ctx.t.ncols), 0)
    end
end

function M.cell_down()
    vertical(1)
end

function M.cell_up()
    vertical(-1)
end

--- Insert a new row (content line + bottom border) after the current row.
function M.new_row()
    local ctx = align_keep_cursor(false)
    if not ctx then
        return
    end
    local lnum = api.nvim_win_get_cursor(0)[1]
    -- bottom border of the current row: first border at or after the cursor
    -- (on the header's `=` separator, insert right below it)
    local b = lnum
    while ctx.t.rows[b - ctx.s + 1].kind ~= "border" do
        b = b + 1
    end
    local border = (render(ctx.t, { kind = "border", fill = "-" }))
    api.nvim_buf_set_lines(0, b, b, false, { empty_row(ctx), border })
    local nctx = align_at(0, b + 1, true)
    if nctx then
        set_cell_cursor(nctx, b + 1, 1, 0)
    end
end

--- Insert a continuation line inside the current row (e.g. another bullet in a cell).
function M.new_line()
    local ctx, c = align_keep_cursor(false)
    if not ctx or not c then
        return
    end
    local lnum = api.nvim_win_get_cursor(0)[1]
    api.nvim_buf_set_lines(0, lnum, lnum, false, { empty_row(ctx) })
    local nctx = align_at(0, lnum + 1, true)
    if nctx then
        set_cell_cursor(nctx, lnum + 1, c, 0)
    end
end

--- Build a new table at the cursor from `spec`:
--- "A, B, C" -> table with that header row; "3" -> headerless table with 3 columns.
local function insert_table(spec)
    spec = vim.trim(spec or "")
    if spec == "" then
        return
    end
    local headers
    local n = tonumber(spec)
    if n then
        if n < 1 or n ~= math.floor(n) then
            return vim.notify("grid table: column count must be a positive integer", vim.log.levels.WARN)
        end
    else
        headers = vim.tbl_map(vim.trim, vim.split(spec, ",", { plain = true }))
        n = #headers
    end
    local indent = api.nvim_get_current_line():match("^(%s*)")
    local t = { indent = indent, ncols = n, widths = {} }
    local empty = {}
    for c = 1, n do
        empty[c] = ""
        t.widths[c] = math.max(3, headers and vim.fn.strdisplaywidth(headers[c]) or 0)
    end
    local function line(r)
        return (render(t, r))
    end
    local tbl = { line({ kind = "border", fill = "-" }) }
    if headers then
        tbl[#tbl + 1] = line({ kind = "row", cells = headers })
        tbl[#tbl + 1] = line({ kind = "border", fill = "=" })
    end
    local body = #tbl + 1
    tbl[#tbl + 1] = line({ kind = "row", cells = empty })
    tbl[#tbl + 1] = line({ kind = "border", fill = "-" })

    -- prettier (conform, format on save) would mangle the table otherwise
    local out = { indent .. "<!-- prettier-ignore-start -->", "" }
    vim.list_extend(out, tbl)
    vim.list_extend(out, { "", indent .. "<!-- prettier-ignore-end -->" })

    local lnum = api.nvim_win_get_cursor(0)[1]
    local first
    if api.nvim_get_current_line():match("^%s*$") then
        api.nvim_buf_set_lines(0, lnum - 1, lnum, false, out) -- replace blank line
        first = lnum + 2
    else
        table.insert(out, 1, "")
        api.nvim_buf_set_lines(0, lnum, lnum, false, out)
        first = lnum + 4
    end
    local ctx = align_at(0, first, true)
    if ctx then
        set_cell_cursor(ctx, first + body - 1, 1, 0)
        vim.cmd.startinsert()
    end
end

--- `\tn`: prompt for headers (or a column count) and insert a new table.
function M.new_table()
    vim.ui.input({ prompt = "Columns (A, B, C — or a number for no header): " }, insert_table)
end

M._insert_table = insert_table -- for testing

local PANDOC = {
    "pandoc",
    "-f",
    "markdown",
    "-t",
    "markdown-pipe_tables-simple_tables-multiline_tables+grid_tables",
    "--columns=80",
}

--- Is the nearest non-blank line from `from` (walking by `step`) a line containing `marker`?
local function has_marker(lines, from, step, marker)
    local i = from
    while lines[i] and lines[i]:match("^%s*$") do
        i = i + step
    end
    return lines[i] ~= nil and lines[i]:find(marker, 1, true) ~= nil
end

--- Run lines s..e (1-based) through pandoc, replacing them with the resulting grid table.
local function convert_range(s, e)
    -- realign grid tables first: pandoc reads misaligned borders as merged cells
    if is_border(api.nvim_buf_get_lines(0, s - 1, s, false)[1]) then
        align_at(0, s, true)
    end
    local lines = api.nvim_buf_get_lines(0, s - 1, e, false)
    local indent = lines[1]:match("^(%s*)")
    local input = vim.tbl_map(function(l)
        return l:sub(1, #indent) == indent and l:sub(#indent + 1) or l
    end, lines)

    local res = vim.system(PANDOC, { stdin = table.concat(input, "\n") .. "\n", text = true }):wait()
    if res.code ~= 0 then
        return vim.notify("grid table: pandoc failed\n" .. (res.stderr or ""), vim.log.levels.ERROR)
    end
    local out = vim.split(vim.trim(res.stdout), "\n", { plain = true })
    if not (is_border(out[1]) and is_border(out[#out])) then
        return vim.notify("grid table: pandoc did not produce a table (is this a table?)", vim.log.levels.WARN)
    end
    for i, l in ipairs(out) do
        out[i] = indent .. l
    end

    -- same prettier-ignore wrapping as \tn, unless it's already there
    local all = api.nvim_buf_get_lines(0, 0, -1, false)
    local top = 0
    if not has_marker(all, e + 1, 1, "prettier-ignore-end") then
        vim.list_extend(out, { "", indent .. "<!-- prettier-ignore-end -->" })
    end
    if not has_marker(all, s - 1, -1, "prettier-ignore-start") then
        table.insert(out, 1, "")
        table.insert(out, 1, indent .. "<!-- prettier-ignore-start -->")
        top = 2
    end
    api.nvim_buf_set_lines(0, s - 1, e, false, out)

    local first = s + top
    local ctx = align_at(0, first, true)
    if not ctx then
        return
    end
    -- first body row: after the header separator if there is one
    local from = first
    for i, r in ipairs(ctx.t.rows) do
        if r.kind == "border" and r.fill == "=" then
            from = ctx.s + i
            break
        end
    end
    local row = row_lines(ctx, from, ctx.e, 1)
    if row then
        set_cell_cursor(ctx, row, 1, 0)
    end
end

--- `\tc`: convert the table under the cursor (pipe/simple/grid) to a grid table via pandoc.
--- In visual mode, converts the selected lines. Pandoc may rewrite cell contents and wraps
--- the table to 80 columns, unlike \ta which only realigns.
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
        local lines = api.nvim_buf_get_lines(0, 0, -1, false)
        local lnum = api.nvim_win_get_cursor(0)[1]
        if lines[lnum]:match("^%s*$") then
            return vim.notify("grid table: cursor is not on a table", vim.log.levels.INFO)
        end
        -- contiguous table-looking lines (grid/pipe), else the paragraph (simple tables)
        local same = is_table_line(lines[lnum]) and is_table_line or function(l)
            return not l:match("^%s*$")
        end
        s, e = lnum, lnum
        while s > 1 and same(lines[s - 1]) do
            s = s - 1
        end
        while e < #lines and same(lines[e + 1]) do
            e = e + 1
        end
    end
    convert_range(s, e)
end

return M
