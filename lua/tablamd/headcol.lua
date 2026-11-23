-- Header column: the first column's body cells written in bold (`**Ana**`), so pandoc renders
-- them as row labels in the PDF. Markdown has no syntax for a header column, so the bold text
-- itself is the marker: a table has a header column when every non-empty body cell of column 1
-- is bold. Pure functions on a parsed table (see core.lua).
local core = require("tablamd.core")

local M = {}

--- Split a cell line into its prefix (indent and list marker, kept outside the bold) and text.
local function split(s)
    local lead, rest = s:match("^(%s*[-*+]%s+)(.*)$")
    if not lead then
        lead, rest = s:match("^(%s*%d+[.)]%s+)(.*)$")
    end
    if not lead then
        lead, rest = s:match("^(%s*)(.*)$")
    end
    return lead, rest
end

function M.is_bold(s)
    local _, rest = split(s)
    return #rest >= 5 and rest:match("^%*%*.*%S%*%*$") ~= nil and rest:sub(3, 3):match("%S") ~= nil
end

--- Text with no bold markers at either end (so not something half typed, like `**Ana`).
local function is_plain(s)
    local _, rest = split(s)
    return rest ~= "" and not rest:find("^%*%*") and not rest:find("%*%*$")
end

function M.bold(s)
    local lead, rest = split(s)
    return lead .. "**" .. rest .. "**"
end

function M.unbold(s)
    local lead, rest = split(s)
    return lead .. rest:sub(3, -3)
end

--- Remove the bold markers from a cell's text (for sorting).
function M.strip(s)
    return M.is_bold(s) and M.unbold(s) or s
end

--- Body blocks of the table (the header row excluded) and the index of the first one.
local function body(t)
    local borders, blocks = core.split_blocks(t)
    return blocks, core.has_header(borders) and 2 or 1
end

--- Does the table have a header column? Block `except` (the row being edited) is ignored.
function M.active(t, except)
    local blocks, first = body(t)
    local bold = 0
    for b = first, #blocks do
        if b ~= except then
            for _, r in ipairs(blocks[b]) do
                local cell = r.cells[1]
                if M.is_bold(cell) then
                    bold = bold + 1
                elseif cell:match("%S") then
                    return false
                end
            end
        end
    end
    return bold > 0
end

--- Apply fn to the first-column cells of the body blocks selected by want(b). Returns the
--- set of changed rows (records).
local function map(t, want, fn)
    local blocks, first = body(t)
    local changed = {}
    for b = first, #blocks do
        if want(b) then
            for _, r in ipairs(blocks[b]) do
                local new = fn(r.cells[1])
                if new and new ~= r.cells[1] then
                    r.cells[1] = new
                    changed[r] = true
                end
            end
        end
    end
    return changed
end

--- Bold the plain first-column cells of block k when the rest of the table has a header
--- column, so a row typed into such a table follows it.
function M.follow(t, k)
    if not M.active(t, k) then
        return {}
    end
    return map(t, function(b)
        return b == k
    end, function(cell)
        return is_plain(cell) and M.bold(cell) or nil
    end)
end

--- Turn the header column on or off. Returns whether it is now on and the changed rows.
function M.toggle(t)
    local on = not M.active(t)
    local all = function()
        return true
    end
    if on then
        return true,
            map(t, all, function(cell)
                return cell:match("%S") and not M.is_bold(cell) and M.bold(cell) or nil
            end)
    end
    return false, map(t, all, function(cell)
        return M.is_bold(cell) and M.unbold(cell) or nil
    end)
end

return M
