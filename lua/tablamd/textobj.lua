-- Cell text objects: `ic` (cell content) and `ac` (everything between the two pipes).
local core = require("tablamd.core")

local M = {}

local api = vim.api

local function select_cell(inner)
    local line = api.nvim_get_current_line()
    if not core.is_row(line) then
        return
    end
    local lnum, col = unpack(api.nvim_win_get_cursor(0))
    local _, seps = core.split_row(line)
    local c = 1
    for k = 1, #seps do
        if seps[k] <= col then
            c = k
        end
    end
    c = math.min(c, #seps - 1)
    if c < 1 then
        return
    end
    -- 0-based, inclusive byte range between the pipes
    local a, b = seps[c] + 1, seps[c + 1] - 1
    if a > b then
        return
    end
    if inner then
        local text = line:sub(a + 1, b + 1)
        local lead, trail = #text:match("^%s*"), #text:match("%s*$")
        if lead == #text then
            b = a -- empty cell: the pad space, so `cic` types in the right place
        else
            a, b = a + lead, b - trail
        end
    end
    if api.nvim_get_mode().mode:match("^[vV\22]") then
        vim.cmd("normal! \27")
    end
    api.nvim_win_set_cursor(0, { lnum, a })
    vim.cmd("normal! v")
    api.nvim_win_set_cursor(0, { lnum, b })
end

function M.inner_cell()
    select_cell(true)
end

function M.outer_cell()
    select_cell(false)
end

return M
