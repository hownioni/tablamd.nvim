-- Pipe tables (GFM / pandoc pipe_tables):
--
--   | Nombre | Edad |
--   | :----- | ---: |
--   | Ana    |   30 |
--
-- They use the same model as grid tables (see core.lua) so every operation works on both:
-- the table is { top border, header, separator, row, border, row, border, ... } where only the
-- separator (`sep = true`) is drawn. Each row is a single line. Rendering matches prettier's
-- markdown formatter exactly, since conform runs prettier on save.
local M = {}

local api = vim.api

local function core()
    return require("tablamd.core")
end

--- Cells of a pipe-table line (outer pipes optional) and the 0-based byte positions of the
--- delimiters around them. A missing outer pipe gets a virtual position just outside the text.
function M.split(l)
    local _, seps = core().split_row(l)
    local indent = #l:match("^%s*")
    local stop = #(l:gsub("%s+$", ""))
    local edges = {}
    local k = 1
    if seps[1] == indent then
        edges[1], k = indent, 2
    else
        edges[1] = indent - 1
    end
    for j = k, #seps do
        edges[#edges + 1] = seps[j]
    end
    if edges[#edges] ~= stop - 1 then
        edges[#edges + 1] = stop
    end
    local cells = {}
    for j = 1, #edges - 1 do
        cells[j] = l:sub(edges[j] + 2, edges[j + 1])
    end
    return cells, edges
end

local function has_pipe(l)
    return l ~= nil and not l:match("^%s*$") and #select(2, core().split_row(l)) > 0
end

--- Is this a pipe-table delimiter line (`| :--- | ---: |`)?
function M.is_sep(l)
    if not has_pipe(l) then
        return false
    end
    local cells = M.split(l)
    for _, c in ipairs(cells) do
        if not vim.trim(c):match("^:?%-+:?$") then
            return false
        end
    end
    return #cells > 0
end

--- Bounds (1-based, inclusive) of the pipe table around lnum: from the header (the line above
--- the delimiter line) to the last consecutive line with a pipe.
function M.find_bounds(buf, lnum)
    local function get(l)
        return api.nvim_buf_get_lines(buf, l - 1, l, false)[1]
    end
    if not has_pipe(get(lnum)) then
        return nil
    end
    local n = api.nvim_buf_line_count(buf)
    local s, e = lnum, lnum
    while s > 1 and has_pipe(get(s - 1)) do
        s = s - 1
    end
    while e < n and has_pipe(get(e + 1)) do
        e = e + 1
    end
    -- the nearest delimiter line at or above the cursor (or just below it, on the header)
    for l = math.min(lnum + 1, e), s + 1, -1 do
        if M.is_sep(get(l)) then
            return l - 1, e
        end
    end
end

function M.parse(tlines, ts)
    local C = core()
    local indent = tlines[1]:match("^(%s*)")
    local sepcells = M.split(tlines[2])
    local ncols = #sepcells
    local aligns = {}
    for c, cell in ipairs(sepcells) do
        local x = vim.trim(cell)
        aligns[c] = { left = x:sub(1, 1) == ":", right = #x > 1 and x:sub(-1) == ":" }
    end
    local function row(l, i)
        local raw = M.split(l)
        if #raw > ncols then
            return nil, ("line %d: %d cells but %d columns (write a literal pipe as \\|)"):format(i, #raw, ncols)
        end
        local cells = {}
        for c = 1, ncols do
            cells[c] = vim.trim(C.expand_tabs(raw[c] or "", ts or 8))
        end
        return { kind = "row", cells = cells }
    end
    local header, err = row(tlines[1], 1)
    if not header then
        return nil, err
    end
    local rows = { C.new_border(ncols, "-"), header, { kind = "border", fill = "=", sep = true, aligns = aligns } }
    for i = 3, #tlines do
        local r, rerr = row(tlines[i], i)
        if not r then
            return nil, rerr
        end
        rows[#rows + 1] = r
        rows[#rows + 1] = C.new_border(ncols, "-")
    end
    return { format = "pipe", indent = indent, ncols = ncols, rows = rows }
end

--- Column widths: at least 3, like prettier. Also caches the separator's alignments.
function M.compute_widths(t)
    local widths = {}
    for c = 1, t.ncols do
        widths[c] = 3
    end
    for _, r in ipairs(t.rows) do
        if r.kind == "row" then
            for c, cell in ipairs(r.cells) do
                widths[c] = math.max(widths[c], api.nvim_strwidth(cell))
            end
        elseif r.sep then
            t.aligns = r.aligns
        end
    end
    t.widths = widths
end

--- Render a row (nil for the undrawn borders). Returns the line and 0-based byte offsets where
--- each cell's text starts (after alignment padding).
function M.render(t, r)
    local pieces, starts = {}, {}
    local len = #t.indent + 2
    for c, w in ipairs(t.widths) do
        local a = (r.kind == "border" and r.aligns or t.aligns or {})[c] or {}
        local piece, lead
        if r.kind == "border" then
            if a.left and a.right then
                piece = ":" .. ("-"):rep(w - 2) .. ":"
            elseif a.left then
                piece = ":" .. ("-"):rep(w - 1)
            elseif a.right then
                piece = ("-"):rep(w - 1) .. ":"
            else
                piece = ("-"):rep(w)
            end
            lead = 0
        else
            local cell = r.cells[c]
            local pad = w - api.nvim_strwidth(cell)
            lead = (a.left and a.right) and math.floor(pad / 2) or (a.right and pad or 0)
            piece = (" "):rep(lead) .. cell .. (" "):rep(pad - lead)
        end
        starts[c] = len + lead
        pieces[c] = piece
        len = len + #piece + 3
    end
    if r.kind == "border" and not r.sep then
        return nil, starts
    end
    return t.indent .. "| " .. table.concat(pieces, " | ") .. " |", starts
end

--- Which cell (index, byte offset into its text) the 0-based col falls in. The index is
--- ncols+1 on or after the closing pipe.
function M.cell_at(line, col)
    local cells, edges = M.split(line)
    local c = 1
    for k = 1, #edges do
        if edges[k] <= col then
            c = k
        end
    end
    local cell = cells[c] or ""
    local lead = #cell:match("^%s*")
    local start = edges[c] + 1 + (lead == #cell and math.min(1, lead) or lead)
    return c, math.max(0, col - start)
end

return M
