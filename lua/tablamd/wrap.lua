-- Wrapping cell text so a grid table fits in a given width (`max_width`), at word
-- boundaries, into continuation lines of the same row. When the table is too wide the widest
-- columns shrink first, never below their longest word. Pure functions on a parsed table.
--
-- A cell's lines are split into units: paragraphs and list items (rewrapped, list items with
-- a hanging indent) and lines kept as they are (blank lines, headings, quotes, code blocks).
local core = require("tablamd.core")
local headcol = require("tablamd.headcol")

local M = {}

local sw = vim.api.nvim_strwidth

--- The configured width for `buf` (b:tablamd_max_width wins), or nil when wrapping is off.
function M.max_width(buf)
    local w = vim.b[buf or 0].tablamd_max_width
    if w == nil then
        w = require("tablamd").config.max_width
    end
    return (w and w ~= 0) and w or nil
end

local function list_marker(l)
    return l:match("^%s*[-*+]%s+") or l:match("^%s*%d+[.)]%s+")
end

--- A word that would turn a line it starts into a list item, heading, quote or setext
--- underline. It is kept on the line before.
local function sticky(tok)
    return tok:match("^[-=*+_]+$") or tok:match("^%d+[.)]$") or tok:match("^#+$") or tok:match("^>")
end

local function units(lines)
    local out, cur, fence = {}, nil, nil
    for idx, l in ipairs(lines) do
        local f = l:match("^%s*(```+)") or l:match("^%s*(~~~+)")
        if fence or f or l:match("^%s*$") or l:match("^%s*#") or l:match("^%s*>") then
            out[#out + 1] = { s = idx, lines = { l } }
            cur = nil
            if fence then
                if f and f:sub(1, 1) == fence:sub(1, 1) and #f >= #fence then
                    fence = nil
                end
            elseif f then
                fence = f
            end
        else
            local m = list_marker(l)
            if m or not cur then
                local prefix = m or l:match("^%s*")
                cur = { s = idx, lines = {}, para = true, prefix = prefix, cont = (" "):rep(sw(prefix)) }
                out[#out + 1] = cur
            end
            table.insert(cur.lines, l)
            if l:match("\\$") then -- hard line break: the paragraph goes on, but not this line
                cur = nil
            end
        end
    end
    for _, u in ipairs(out) do
        if u.para then
            -- a cell bold on every line (header column) is bolded line by line again
            u.bold = true
            for _, l in ipairs(u.lines) do
                u.bold = u.bold and headcol.is_bold(l)
            end
            local toks = {}
            for n, l in ipairs(u.lines) do
                local text = u.bold and headcol.unbold(l) or l
                if n == 1 then
                    text = text:sub(#u.prefix + 1)
                end
                for tok in text:gmatch("%S+") do
                    if #toks > 0 and sticky(tok) then
                        toks[#toks] = toks[#toks] .. " " .. tok
                    else
                        toks[#toks + 1] = tok
                    end
                end
            end
            u.toks = toks
        end
    end
    return out
end

--- Natural (one line) and minimum (longest word) width of a unit.
local function unit_widths(u)
    if not u.para then
        local w = sw(u.lines[1])
        return w, w
    end
    local extra = sw(u.prefix) + (u.bold and 4 or 0)
    local longest = 0
    for _, tok in ipairs(u.toks) do
        longest = math.max(longest, sw(tok))
    end
    return extra + sw(table.concat(u.toks, " ")), extra + longest
end

local function wrap_unit(u, w)
    local extra = u.bold and 4 or 0
    local out, line = {}, nil
    for _, tok in ipairs(u.toks) do
        if not line then
            line = u.prefix .. tok
        elseif sw(line) + 1 + sw(tok) + extra <= w then
            line = line .. " " .. tok
        else
            out[#out + 1] = line
            line = u.cont .. tok
        end
    end
    out[#out + 1] = line or u.prefix
    if u.bold then
        out = vim.tbl_map(headcol.bold, out)
    end
    return out
end

local function too_wide(lines, w)
    for _, l in ipairs(lines) do
        if sw(l) > w then
            return true
        end
    end
    return false
end

--- Shrink the widest columns, one display cell at a time, until they fit in `avail`.
local function allocate(base, minw, avail)
    local w, total = {}, 0
    for c, b in ipairs(base) do
        w[c], total = b, total + b
    end
    while total > avail do
        local best
        for c = 1, #w do
            if w[c] > minw[c] and (not best or w[c] > w[best]) then
                best = c
            end
        end
        if not best then
            break -- even the longest words don't fit: as narrow as it gets
        end
        w[best], total = w[best] - 1, total - 1
    end
    return w
end

-- Cursor tracking: wrapping only changes whitespace (and bold markers, in a bold cell), so a
-- position is the number of other bytes before it.
local function counter(bold)
    return function(ch)
        return ch:match("%S") ~= nil and not (bold and ch == "*")
    end
end

local function count_before(lines, line, off, sig)
    local n = 0
    for j = 1, line do
        local l = lines[j]
        local upto = j == line and math.min(off, #l) or #l
        for b = 1, upto do
            if sig(l:sub(b, b)) then
                n = n + 1
            end
        end
    end
    return n
end

--- Line and offset in `lines` after `n` counted bytes; on the next counted byte when `on`.
local function locate(lines, n, on, sig)
    local seen = 0
    for j, l in ipairs(lines) do
        for b = 1, #l do
            if sig(l:sub(b, b)) then
                if seen == n then
                    return j, b - 1
                end
                seen = seen + 1
                if seen == n and not on then
                    return j, b
                end
            end
        end
    end
    return #lines, #lines[#lines]
end

--- Wrap the cells of grid table `t` so the table (borders included, indentation not) is at
--- most `max` wide. Only paragraphs with a line too wide are rewrapped, unless `full`: then
--- every paragraph is joined and wrapped again, for the narrowest layout that fits.
--- `target` ({ i, c, off }, optional) is a cursor position, moved along with its text.
--- Returns whether anything changed.
function M.fit(t, max, full, target)
    if t.format == "pipe" then
        return false
    end
    local borders, blocks = core.split_blocks(t)
    local ncols = t.ncols
    local cur, nat, minw, cells = {}, {}, {}, {}
    for c = 1, ncols do
        cur[c], nat[c], minw[c] = 1, 1, 1
    end
    for k, b in ipairs(blocks) do
        cells[k] = {}
        for c = 1, ncols do
            local lines = {}
            for o, r in ipairs(b) do
                lines[o] = r.cells[c]
                cur[c] = math.max(cur[c], sw(r.cells[c]))
            end
            cells[k][c] = units(lines)
            for _, u in ipairs(cells[k][c]) do
                local n, m = unit_widths(u)
                nat[c], minw[c] = math.max(nat[c], n), math.max(minw[c], m)
            end
        end
    end
    local w = allocate(full and nat or cur, minw, max - 3 * ncols - 1)

    local trec = target and t.rows[target.i]
    local tk, to
    if trec and trec.kind == "row" then
        tk, to = core.block_of(t, target.i)
    end
    local moved -- new line in block tk (and offset) of the cursor
    local changed = false
    for k, b in ipairs(blocks) do
        local cols, height, touched = {}, full and 1 or #b, false
        local tline, toff
        for c = 1, ncols do
            local out = {}
            for _, u in ipairs(cells[k][c]) do
                local new = u.lines
                if u.para and (full or too_wide(u.lines, w[c])) then
                    new = wrap_unit(u, w[c])
                    touched = touched or not vim.deep_equal(new, u.lines)
                end
                if k == tk and c == target.c and to >= u.s and to < u.s + #u.lines then
                    if new ~= u.lines then
                        local sig = counter(u.bold)
                        local line, off = to - u.s + 1, target.off or 0
                        local n = count_before(u.lines, line, off, sig)
                        local l = u.lines[line]
                        local on = off < #l and sig(l:sub(off + 1, off + 1))
                        local j, o = locate(new, n, on, sig)
                        tline, toff = #out + j, o
                    else
                        tline = #out + to - u.s + 1
                    end
                end
                vim.list_extend(out, new)
            end
            while #out > 0 and out[#out] == "" do
                out[#out] = nil
            end
            height = math.max(height, #out)
            cols[c] = out
        end
        if touched then
            changed = true
            local rows = {}
            for o = 1, height do
                local r = b[o] or core.new_row(ncols)
                for c = 1, ncols do
                    r.cells[c] = cols[c][o] or ""
                end
                rows[o] = r
            end
            blocks[k] = rows
        end
        if k == tk then
            moved = { line = math.min(tline or to, #blocks[k]), off = touched and toff or nil }
        end
    end
    if not changed then
        return false
    end
    core.join_blocks(t, borders, blocks)
    if target then
        local rec = tk and blocks[tk][moved.line] or trec
        for i, r in ipairs(t.rows) do
            if r == rec then
                target.i = i
            end
        end
        if moved and moved.off then
            target.off = moved.off
        end
    end
    return true
end

return M
