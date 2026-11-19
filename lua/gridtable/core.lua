-- Pure parsing/rendering of grid tables (and, via pipe.lua, pipe tables). No cursor or keymap
-- logic here. A parsed table `t` is { format, indent, ncols, rows, widths } where each row is
--   { kind = "border", fill = "-"|"=", aligns = { {left=, right=}, ... }, sep = pipe delimiter? }
--   { kind = "row", cells = { "text", ... } }
-- After render_all, t.lnum maps a row index to its line in the table (nil for undrawn pipe
-- borders) and t.index maps a line back to its row index.
local M = {}

local api = vim.api

function M.is_border(l)
    return l:match("^%s*%+[-=:+]*%+%s*$") ~= nil and l:find("[-=]") ~= nil
end

function M.is_row(l)
    return l:match("^%s*|") ~= nil
end

function M.is_table_line(l)
    return M.is_border(l) or M.is_row(l)
end

--- Split a row on unescaped `|`. Returns cells and 0-based byte offsets of each separator.
function M.split_row(s)
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

--- Escape every unescaped `|` as `\|`.
function M.escape(s)
    local out, i = {}, 1
    while i <= #s do
        local ch = s:sub(i, i)
        if ch == "\\" then
            out[#out + 1] = s:sub(i, i + 1)
            i = i + 2
        else
            out[#out + 1] = ch == "|" and "\\|" or ch
            i = i + 1
        end
    end
    return table.concat(out)
end

--- 0-based byte offsets of the `+` corners of a border line.
function M.border_seps(l)
    local seps, i = {}, 0
    while true do
        i = l:find("+", i + 1, true)
        if not i then
            return seps
        end
        seps[#seps + 1] = i - 1
    end
end

--- Expand tabs to spaces (tab stops counted from the start of the cell). A tab's display
--- width depends on its screen column, so left in place it would break the alignment.
function M.expand_tabs(s, ts)
    if not s:find("\t", 1, true) then
        return s
    end
    local out, col = {}, 0
    for piece, tab in s:gmatch("([^\t]*)(\t?)") do
        out[#out + 1] = piece
        col = col + api.nvim_strwidth(piece)
        if tab ~= "" then
            local n = ts - col % ts
            out[#out + 1] = (" "):rep(n)
            col = col + n
        end
    end
    return table.concat(out)
end

--- Strip exactly one leading pad space and trailing whitespace, keeping inner indentation.
function M.norm_cell(c, ts)
    c = c:gsub("^ ", "")
    return (M.expand_tabs(c, ts or 8):gsub("%s+$", ""))
end

--- Number of columns of a border line.
function M.border_ncols(l)
    local _, plus = vim.trim(l):gsub("%+", "")
    return plus - 1
end

--- Find table bounds (1-based, inclusive) around lnum, reading only the table's own lines.
--- The table must start and end with a border.
function M.find_bounds(buf, lnum)
    local function get(l)
        return api.nvim_buf_get_lines(buf, l - 1, l, false)[1]
    end
    local cur = get(lnum)
    if not cur or not M.is_table_line(cur) then
        return nil
    end
    local n = api.nvim_buf_line_count(buf)
    local s, e, first, last = lnum, lnum, cur, cur
    while s > 1 do
        local l = get(s - 1)
        if not M.is_table_line(l) then
            break
        end
        s, first = s - 1, l
    end
    while e < n do
        local l = get(e + 1)
        if not M.is_table_line(l) then
            break
        end
        e, last = e + 1, l
    end
    if not (M.is_border(first) and M.is_border(last)) then
        return nil
    end
    return s, e
end

function M.new_border(ncols, fill)
    local aligns = {}
    for c = 1, ncols do
        aligns[c] = {}
    end
    return { kind = "border", fill = fill or "-", aligns = aligns }
end

function M.new_row(ncols)
    local cells = {}
    for c = 1, ncols do
        cells[c] = ""
    end
    return { kind = "row", cells = cells }
end

local function parse_grid(tlines, ts)
    local indent = tlines[1]:match("^(%s*)")
    local ncols = M.border_ncols(tlines[1])
    local rows = {}
    for i, l in ipairs(tlines) do
        if M.is_border(l) then
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
            local raw = M.split_row(l)
            if #raw > ncols then
                return nil, ("line %d: %d cells but %d columns (write a literal pipe as \\|)"):format(i, #raw, ncols)
            end
            local cells = {}
            for c = 1, ncols do
                cells[c] = M.norm_cell(raw[c] or "", ts)
            end
            rows[i] = { kind = "row", cells = cells }
        end
    end
    return { format = "grid", indent = indent, ncols = ncols, rows = rows }
end

--- Parse table lines of the given format ("grid" or "pipe").
function M.parse(tlines, ts, format)
    local t, err
    if format == "pipe" then
        t, err = require("gridtable.pipe").parse(tlines, ts)
    else
        t, err = parse_grid(tlines, ts)
    end
    if t then
        M.index_lines(t)
    end
    return t, err
end

--- Bounds and format of the table around lnum: a grid table, else a pipe table.
function M.find_table(buf, lnum)
    local s, e = M.find_bounds(buf, lnum)
    if s then
        return s, e, "grid"
    end
    s, e = require("gridtable.pipe").find_bounds(buf, lnum)
    if s then
        return s, e, "pipe"
    end
end

--- Set t.lnum (row index -> line in the table) and t.index (line -> row index).
function M.index_lines(t)
    local lnum, index, n = {}, {}, 0
    for i, r in ipairs(t.rows) do
        if t.format ~= "pipe" or r.kind == "row" or r.sep then
            n = n + 1
            lnum[i], index[n] = n, i
        end
    end
    t.lnum, t.index = lnum, index
end

function M.compute_widths(t)
    if t.format == "pipe" then
        return require("gridtable.pipe").compute_widths(t)
    end
    local widths = {}
    for c = 1, t.ncols do
        widths[c] = 1
    end
    for _, r in ipairs(t.rows) do
        if r.kind == "row" then
            for c, cell in ipairs(r.cells) do
                widths[c] = math.max(widths[c], api.nvim_strwidth(cell))
            end
        end
    end
    t.widths = widths
end

--- Render one row; returns the line and 0-based byte offsets where each cell's content starts
--- (for a border: where each segment starts).
function M.render(t, r)
    if t.format == "pipe" then
        return require("gridtable.pipe").render(t, r)
    end
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
        -- starts: where each segment's fill begins (just after its `+`)
        local starts, len = {}, #t.indent + 1
        for c, seg in ipairs(segs) do
            starts[c] = len
            len = len + #seg + 1
        end
        return t.indent .. "+" .. table.concat(segs, "+") .. "+", starts
    end
    local out, starts = { t.indent, "|" }, {}
    local len = #t.indent + 1
    for c, w in ipairs(t.widths) do
        local cell = r.cells[c]
        starts[c] = len + 1
        local piece = " " .. cell .. (" "):rep(w - api.nvim_strwidth(cell)) .. " |"
        out[#out + 1] = piece
        len = len + #piece
    end
    return table.concat(out), starts
end

--- Render the whole table (recomputing widths). Returns lines and per-row cell starts.
function M.render_all(t)
    M.compute_widths(t)
    local lines, starts = {}, {}
    for i, r in ipairs(t.rows) do
        local l
        l, starts[i] = M.render(t, r)
        if l then
            lines[#lines + 1] = l
        end
    end
    M.index_lines(t)
    return lines, starts
end

--- Which column (index, byte offset into its content) the 0-based col falls in.
--- For a border line the offset is always 0. The index may be ncols+1 past the closing pipe.
function M.cell_at(line, col)
    local border = M.is_border(line)
    local seps = border and M.border_seps(line) or select(2, M.split_row(line))
    local c = 1
    for k = 1, #seps do
        if seps[k] <= col then
            c = k
        end
    end
    if border then
        return math.min(c, math.max(1, #seps - 1)), 0
    end
    local start = seps[c] + 1
    if line:sub(start + 1, start + 1) == " " then
        start = start + 1
    end
    return c, math.max(0, col - start)
end

--- Group a table into alternating borders and row blocks:
--- borders[1], blocks[1], borders[2], ..., blocks[n], borders[n+1].
--- Each block is a list of row records (a multi-line row). Adjacent borders give an empty block.
function M.split_blocks(t)
    local borders, blocks = {}, {}
    for _, r in ipairs(t.rows) do
        if r.kind == "border" then
            if #borders > 0 and not blocks[#borders] then
                blocks[#borders] = {}
            end
            borders[#borders + 1] = r
        else
            local b = blocks[#borders] or {}
            blocks[#borders] = b
            b[#b + 1] = r
        end
    end
    -- drop the trailing (nonexistent) block after the bottom border
    blocks[#borders] = nil
    return borders, blocks
end

--- Inverse of split_blocks: sets t.rows.
function M.join_blocks(t, borders, blocks)
    local rows = { borders[1] }
    for k, b in ipairs(blocks) do
        vim.list_extend(rows, b)
        rows[#rows + 1] = borders[k + 1]
    end
    t.rows = rows
end

--- Index into t.rows of line `o` (1-based) of block `k`, given the blocks list.
function M.row_index(blocks, k, o)
    local idx = 1
    for b = 1, k - 1 do
        idx = idx + #blocks[b] + 1
    end
    return idx + (o or 1)
end

--- Block index and line-in-block for row index i. A border maps to the block above it
--- (the top border to block 1) with line 0.
function M.block_of(t, i)
    local k, o = 0, 0
    for j = 1, i do
        if t.rows[j].kind == "border" then
            k, o = k + 1, 0
        else
            o = o + 1
        end
    end
    if o == 0 then
        return math.max(1, k - 1), 0
    end
    return k, o
end

--- Does the table have a header (first block followed by a `=` border)?
function M.has_header(borders)
    -- a pipe table always has a header, even with no body rows
    return borders[2] ~= nil and (borders[2].sep or (borders[2].fill == "=" and #borders > 2))
end

return M
