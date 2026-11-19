-- gridtable.nvim: edit Pandoc grid tables in Markdown.
-- Pure Lua (no pandoc round-trip except for `convert`), so cell contents are kept verbatim.
local M = {}

local api = vim.api

M.defaults = {
    filetypes = { "markdown" },
    -- realign the table on InsertLeave (per buffer: `b:gridtable_autoalign = v:false`)
    auto_align = true,
    -- turn 'wrap' off while the cursor is on a table line, restore it when leaving
    nowrap = true,
    -- typing `|` inside a complete row inserts `\|` (per buffer: `b:gridtable_escape_pipes = v:false`)
    escape_pipes = true,
    -- wrap new/converted tables in <!-- prettier-ignore-start/end -->
    prettier_ignore = true,
    pandoc = {
        "pandoc",
        "-f",
        "markdown",
        "-t",
        "markdown-pipe_tables-simple_tables-multiline_tables+grid_tables",
        "--columns=80",
    },
    -- register which-key groups for the <localleader>t prefixes
    which_key = true,
    -- set any key to false to disable it
    keymaps = {
        new_table = "<localleader>tn",
        align = "<localleader>ta",
        convert = "<localleader>tc",
        next_cell = "<A-l>",
        prev_cell = "<A-h>",
        cell_down = "<A-j>",
        cell_up = "<A-k>",
        new_row = "<A-o>",
        new_line = "<A-CR>",
        insert_col = "<localleader>tic",
        insert_col_before = "<localleader>tiC",
        delete_col = "<localleader>tdc",
        move_col_left = "<A-H>",
        move_col_right = "<A-L>",
        delete_row = "<localleader>tdr",
        move_row_down = "<A-J>",
        move_row_up = "<A-K>",
        cycle_align = "<localleader>tA",
        toggle_header = "<localleader>th",
        inner_cell = "ic",
        outer_cell = "ac",
    },
}

M.config = vim.deepcopy(M.defaults)

--- name -> { module, modes, desc, nav = bool }. `nav` maps are only active inside a table
--- and otherwise fall back to the key's global mapping (e.g. move-line on <A-j>).
M.actions = {
    new_table = { "convert", { "n" }, "new table" },
    align = { "edit", { "n" }, "align" },
    convert = { "convert", { "n", "x" }, "convert/rewrap (pandoc)" },
    next_cell = { "edit", { "n", "i" }, "next cell", nav = true },
    prev_cell = { "edit", { "n", "i" }, "previous cell", nav = true },
    cell_down = { "edit", { "n", "i" }, "cell below", nav = true },
    cell_up = { "edit", { "n", "i" }, "cell above", nav = true },
    new_row = { "edit", { "n", "i" }, "new row below", nav = true },
    new_line = { "edit", { "n", "i" }, "new line inside row", nav = true },
    insert_col = { "edit", { "n" }, "insert column right" },
    insert_col_before = { "edit", { "n" }, "insert column left" },
    delete_col = { "edit", { "n" }, "delete column" },
    move_col_left = { "edit", { "n", "i" }, "move column left", nav = true },
    move_col_right = { "edit", { "n", "i" }, "move column right", nav = true },
    delete_row = { "edit", { "n" }, "delete row" },
    move_row_down = { "edit", { "n", "i" }, "move row down", nav = true },
    move_row_up = { "edit", { "n", "i" }, "move row up", nav = true },
    cycle_align = { "edit", { "n" }, "cycle column alignment" },
    toggle_header = { "edit", { "n" }, "toggle header row" },
    inner_cell = { "textobj", { "x", "o" }, "inner cell" },
    outer_cell = { "textobj", { "x", "o" }, "around cell" },
}

function M.call(name, ...)
    local a = M.actions[name]
    return require("gridtable." .. a[1])[name](...)
end

function M.in_table()
    return require("gridtable.edit").in_table()
end

-- global mappings shadowed by nav keys, called back outside a table
local fallbacks = {}

function M._fallback(id)
    fallbacks[id]()
end

--- A function returning the keys that run `orig` (a maparg() dict) from an expr mapping.
local function fallback_keys(orig)
    if orig.callback and orig.expr == 1 then
        return orig.callback
    elseif orig.callback then
        fallbacks[#fallbacks + 1] = orig.callback
        local keys = ("<Cmd>lua require('gridtable')._fallback(%d)<CR>"):format(#fallbacks)
        return function()
            return keys
        end
    end
    return function()
        if orig.expr == 1 and orig.rhs then
            return api.nvim_eval(orig.rhs)
        end
        return orig.rhs or ""
    end
end

local function map_action(buf, name, lhs)
    local a = M.actions[name]
    local desc = "grid table: " .. a[3]
    for _, mode in ipairs(a[2]) do
        if a.nav then
            local fallback = fallback_keys(vim.fn.maparg(lhs, mode, false, true))
            vim.keymap.set(mode, lhs, function()
                if M.in_table() then
                    return ("<Cmd>lua require('gridtable').call(%q)<CR>"):format(name)
                end
                return fallback()
            end, { buffer = buf, expr = true, silent = true, desc = desc })
        else
            vim.keymap.set(mode, lhs, function()
                M.call(name)
            end, { buffer = buf, silent = true, desc = desc })
        end
    end
end

local function which_key(buf)
    local ok, wk = pcall(require, "which-key")
    if not ok then
        return
    end
    wk.add({
        { "<localleader>t", group = "Table", mode = { "n", "x" }, buffer = buf },
        { "<localleader>ti", group = "Insert", buffer = buf },
        { "<localleader>td", group = "Delete", buffer = buf },
    })
end

--- Set up keymaps and autocommands in `buf` (0 or nil: current buffer).
function M.attach(buf)
    buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
    if vim.b[buf].gridtable_attached then
        return
    end
    vim.b[buf].gridtable_attached = true
    local cfg = M.config

    for name, lhs in pairs(cfg.keymaps) do
        if lhs and M.actions[name] then
            map_action(buf, name, lhs)
        end
    end
    if cfg.which_key then
        which_key(buf)
    end

    local group = api.nvim_create_augroup("gridtable-" .. buf, { clear = true })
    if cfg.auto_align then
        api.nvim_create_autocmd("InsertLeave", {
            buffer = buf,
            group = group,
            callback = function()
                require("gridtable.edit").auto_align()
            end,
        })
    end
    if cfg.escape_pipes then
        api.nvim_create_autocmd("InsertCharPre", {
            buffer = buf,
            group = group,
            callback = function()
                require("gridtable.edit").escape_typed_pipe()
            end,
        })
    end
    if cfg.nowrap then
        api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufWinEnter" }, {
            buffer = buf,
            group = group,
            callback = function()
                local on_table = api.nvim_get_current_line():match("^%s*[|+]") ~= nil and M.in_table()
                if on_table and vim.w.gridtable_saved_wrap == nil then
                    vim.w.gridtable_saved_wrap = vim.wo.wrap
                    vim.opt_local.wrap = false
                elseif not on_table and vim.w.gridtable_saved_wrap ~= nil then
                    vim.opt_local.wrap = vim.w.gridtable_saved_wrap
                    vim.w.gridtable_saved_wrap = nil
                end
            end,
        })
    end
end

function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
    local group = api.nvim_create_augroup("gridtable", { clear = true })
    api.nvim_create_autocmd("FileType", {
        group = group,
        pattern = M.config.filetypes,
        callback = function(ev)
            M.attach(ev.buf)
        end,
    })
    -- buffers that were already open (e.g. when lazy-loaded on FileType)
    for _, buf in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(buf) and vim.tbl_contains(M.config.filetypes, vim.bo[buf].filetype) then
            M.attach(buf)
        end
    end
end

return M
