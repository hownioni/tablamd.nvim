local gt = require("migu.gridtable")

local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = true, silent = true, desc = desc })
end

--- Inside a grid table run `fn`; elsewhere fall back to the global mapping of `lhs`
--- (e.g. <A-j>/<A-k> = move line, from migu.keymaps).
local function table_or_global(modes, lhs, fn, desc)
    for _, mode in ipairs(modes) do
        local orig = vim.fn.maparg(lhs, mode, false, true)
        vim.keymap.set(mode, lhs, function()
            if gt.in_table() then
                return "<Cmd>lua require('migu.gridtable')." .. fn .. "()<CR>"
            end
            return orig.rhs or ""
        end, { buffer = true, expr = true, silent = true, desc = desc })
    end
end

-- Pandoc grid tables (see lua/migu/gridtable.lua)
local ok, wk = pcall(require, "which-key")
if ok then
    wk.add({ { "<localleader>t", group = "Table", mode = { "n", "x" }, buffer = 0 } })
end
map("n", "<localleader>tn", gt.new_table, "new table")
map("n", "<localleader>ta", gt.align, "align")
map({ "n", "x" }, "<localleader>tc", gt.convert, "convert/rewrap (pandoc)")

-- (alt+l is free in kitty; ctrl+t opens tabs in the current dir instead)
map({ "n", "i" }, "<A-l>", gt.next_cell, "grid table: next cell")
map({ "n", "i" }, "<A-h>", gt.prev_cell, "grid table: previous cell")
table_or_global({ "n", "i" }, "<A-j>", "cell_down", "grid table: cell below / move line down")
table_or_global({ "n", "i" }, "<A-k>", "cell_up", "grid table: cell above / move line up")
map({ "n", "i" }, "<A-o>", gt.new_row, "grid table: new row below")
map({ "n", "i" }, "<A-CR>", gt.new_line, "grid table: new line inside row")

local group = vim.api.nvim_create_augroup("gridtable-" .. vim.api.nvim_get_current_buf(), { clear = true })

-- Realign after each insert; disable per buffer with `:let b:gridtable_autoalign = v:false`
vim.api.nvim_create_autocmd("InsertLeave", {
    buffer = 0,
    group = group,
    callback = gt.auto_align,
})

-- No soft-wrap while the cursor is on a table line (prose mode turns wrap on for markdown)
vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufWinEnter" }, {
    buffer = 0,
    group = group,
    callback = function()
        local on_table = vim.api.nvim_get_current_line():match("^%s*[|+]") ~= nil and gt.in_table()
        if on_table and vim.w.gridtable_saved_wrap == nil then
            vim.w.gridtable_saved_wrap = vim.wo.wrap
            vim.opt_local.wrap = false
        elseif not on_table and vim.w.gridtable_saved_wrap ~= nil then
            vim.opt_local.wrap = vim.w.gridtable_saved_wrap
            vim.w.gridtable_saved_wrap = nil
        end
    end,
})
