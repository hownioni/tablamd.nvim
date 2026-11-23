-- tablamd.nvim: edit Pandoc grid tables in Markdown.
-- Pure Lua (no pandoc round-trip except for `convert`), so cell contents are kept verbatim.
local M = {}

local api = vim.api

M.defaults = {
    filetypes = { "markdown" },
    -- realign the table on InsertLeave (per buffer: `b:tablamd_autoalign = v:false`)
    auto_align = true,
    -- turn 'wrap' off while the cursor is on a table line, restore it when leaving
    nowrap = true,
    -- typing `|` inside a complete row inserts `\|` (per buffer: `b:tablamd_escape_pipes = v:false`)
    escape_pipes = true,
    -- what \tn creates: "pipe", "grid", or "ask" (asks each time, last choice first)
    new_table_format = "pipe",
    -- wrap grid-table cells on realign so the table is at most this wide (borders included,
    -- indentation not); match pandoc's --columns. false: off (per buffer: b:tablamd_max_width)
    max_width = false,
    -- wrap new/converted grid tables in <!-- prettier-ignore-start/end -->
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
        convert = "<localleader>tc", -- toggle grid <-> pipe
        pandoc = "<localleader>tC", -- convert any table to grid through pandoc, wrapping cells
        -- inside a table; elsewhere these keys do what they did before
        next_cell = "<Tab>", -- on the last cell: adds a row
        prev_cell = "<S-Tab>",
        cell_down = "<CR>", -- same column, next row (multi-line rows count once); on the last row: adds a row
        cell_up = "<S-CR>",
        new_row = "<A-o>",
        new_row_above = "<A-O>",
        new_line = "<A-CR>", -- continuation line inside the current row
        -- move things: <A-hjkl> = column left, row down, row up, column right.
        -- <A-j>/<A-k> are the table-aware version of a move-line mapping.
        move_col_left = "<A-h>",
        move_row_down = "<A-j>",
        move_row_up = "<A-k>",
        move_col_right = "<A-l>",
        insert_col = "<localleader>tic",
        insert_col_before = "<localleader>tiC",
        delete_col = "<localleader>tdc",
        delete_row = "<localleader>tdr",
        duplicate_row = "<localleader>tyr", -- copy the row below it
        duplicate_col = "<localleader>tyc", -- copy the column right of it
        cycle_align = "<localleader>tA",
        toggle_header = "<localleader>th",
        toggle_header_col = "<localleader>tH", -- first column as row labels (bold, protected)
        sort = "<localleader>ts",
        sort_desc = "<localleader>tS",
        join_row = "<localleader>tj",
        break_row = "<localleader>tb",
        rewrap = "<localleader>tw", -- rewrap every cell to fit max_width (80 when off)
        inner_cell = "ic",
        outer_cell = "ac",
    },
}

M.config = vim.deepcopy(M.defaults)

--- name -> { module, modes, desc, nav = bool, count = "repeat"|"arg" }. `nav` maps are only active inside a table
--- (and no snippet is active); otherwise the key does what it would without the plugin.
M.actions = {
    new_table = { "convert", { "n" }, "new table" },
    align = { "edit", { "n" }, "align" },
    convert = { "convert", { "n", "x" }, "toggle grid/pipe" },
    pandoc = { "convert", { "n", "x" }, "convert to grid via pandoc (rewrap)" },
    next_cell = { "edit", { "n", "i" }, "next cell", nav = true, count = "repeat" },
    prev_cell = { "edit", { "n", "i" }, "previous cell", nav = true, count = "repeat" },
    cell_down = { "edit", { "n", "i" }, "cell below", nav = true, count = "repeat" },
    cell_up = { "edit", { "n", "i" }, "cell above", nav = true, count = "repeat" },
    new_row = { "edit", { "n", "i" }, "new row below", nav = true, count = "repeat" },
    new_row_above = { "edit", { "n", "i" }, "new row above", nav = true, count = "repeat" },
    new_line = { "edit", { "n", "i" }, "new line inside row", nav = true, count = "repeat" },
    insert_col = { "edit", { "n" }, "insert column right", count = "repeat" },
    insert_col_before = { "edit", { "n" }, "insert column left", count = "repeat" },
    delete_col = { "edit", { "n" }, "delete column", count = "arg" },
    move_col_left = { "edit", { "n", "i" }, "move column left", nav = true, count = "arg" },
    move_col_right = { "edit", { "n", "i" }, "move column right", nav = true, count = "arg" },
    delete_row = { "edit", { "n" }, "delete row", count = "arg" },
    duplicate_row = { "edit", { "n" }, "duplicate row", count = "repeat" },
    duplicate_col = { "edit", { "n" }, "duplicate column", count = "repeat" },
    move_row_down = { "edit", { "n", "i" }, "move row down", nav = true, count = "arg" },
    move_row_up = { "edit", { "n", "i" }, "move row up", nav = true, count = "arg" },
    cycle_align = { "edit", { "n" }, "cycle column alignment", count = "repeat" },
    toggle_header = { "edit", { "n" }, "toggle header row" },
    toggle_header_col = { "edit", { "n" }, "toggle header column" },
    sort = { "edit", { "n" }, "sort rows by column" },
    sort_desc = { "edit", { "n" }, "sort rows by column (descending)" },
    join_row = { "edit", { "n" }, "join row lines" },
    break_row = { "edit", { "n" }, "break row into rows" },
    rewrap = { "edit", { "n" }, "rewrap cells to max width" },
    inner_cell = { "textobj", { "x", "o" }, "inner cell" },
    outer_cell = { "textobj", { "x", "o" }, "around cell" },
}

--- Run an action. `count` defaults to the typed count (v:count1), which is only meaningful
--- straight from a mapping: v:count keeps the last count typed. Actions marked
--- `count = "repeat"` run that many times; `count = "arg"` get it as their argument.
function M.call(name, count)
    local a = M.actions[name]
    local fn = require("tablamd." .. a[1])[name]
    count = tonumber(count) or vim.v.count1
    if a.count == "arg" then
        return fn(count)
    elseif a.count == "repeat" then
        for _ = 1, count do
            fn()
        end
        return
    end
    return fn()
end

function M.in_table()
    return require("tablamd.edit").in_table()
end

--- For completion plugins that own <Tab> in insert mode (e.g. blink.cmp): run a nav action
--- if the cursor is in a table of an attached buffer. Returns true when it handled the key.
---   ["<Tab>"] = { "snippet_forward", function() return require("tablamd").try("next_cell") end, "fallback" }
function M.try(name)
    if not vim.b.tablamd_attached or not M.in_table() then
        return false
    end
    -- the caller may be inside an expr mapping, where the buffer can't be changed
    vim.schedule(function()
        M.call(name, 1) -- v:count is stale by now
    end)
    return true
end

-- non-expr Lua callbacks of shadowed global mappings, run through <Cmd>
local callbacks = {}

function M._fallback(id)
    callbacks[id]()
end

--- The global (non-buffer) mapping of `lhs`. Looked up when the key is pressed, not when
--- attaching: plugins like nvim-autopairs only map their keys on the first InsertEnter.
local function global_map(mode, lhs)
    local want = vim.keycode(lhs)
    for _, m in ipairs(api.nvim_get_keymap(mode)) do
        if vim.keycode(m.lhs) == want then
            return m
        end
    end
end

--- Keys (already encoded) that do whatever `lhs` would do without our buffer mapping.
--- Encoding follows the original mapping: a Vimscript <expr> or a Lua expr with
--- replace_keycodes = false returns raw keys (nvim-autopairs does), which must not be
--- encoded twice.
local function fallback_keys(mode, lhs)
    local m = global_map(mode, lhs)
    if not m then
        return vim.keycode(lhs) -- built-in behaviour (our mapping is noremap)
    end
    if m.callback then
        if m.expr == 1 then
            local keys = m.callback() or ""
            return m.replace_keycodes == 1 and vim.keycode(keys) or keys
        end
        local id = tostring(m.callback)
        callbacks[id] = m.callback
        return vim.keycode(("<Cmd>lua require('tablamd')._fallback(%q)<CR>"):format(id))
    end
    if m.expr == 1 then
        local keys = api.nvim_eval(m.rhs)
        return m.replace_keycodes == 1 and vim.keycode(keys) or keys
    end
    return vim.keycode(m.rhs or lhs)
end

--- While a snippet is being filled in, <Tab> & co. belong to the snippet engine.
local function snippet_active()
    if vim.snippet and vim.snippet.active() then
        return true
    end
    local ms = rawget(_G, "MiniSnippets")
    return ms ~= nil and ms.session.get() ~= nil
end

local function map_action(buf, name, lhs)
    local a = M.actions[name]
    local desc = "tablamd: " .. a[3]
    for _, mode in ipairs(a[2]) do
        if a.nav then
            vim.keymap.set(mode, lhs, function()
                if M.in_table() and not snippet_active() then
                    return vim.keycode(("<Cmd>lua require('tablamd').call(%q)<CR>"):format(name))
                end
                return fallback_keys(mode, lhs)
            end, { buffer = buf, expr = true, replace_keycodes = false, silent = true, desc = desc })
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
        { "<localleader>ty", group = "Duplicate", buffer = buf },
    })
end

--- Set up keymaps and autocommands in `buf` (0 or nil: current buffer).
function M.attach(buf)
    buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
    if vim.b[buf].tablamd_attached then
        return
    end
    vim.b[buf].tablamd_attached = true
    local cfg = M.config

    for name, lhs in pairs(cfg.keymaps) do
        if lhs and M.actions[name] then
            map_action(buf, name, lhs)
        end
    end
    if cfg.which_key then
        which_key(buf)
    end

    local group = api.nvim_create_augroup("tablamd-" .. buf, { clear = true })
    if cfg.auto_align then
        api.nvim_create_autocmd("InsertLeave", {
            buffer = buf,
            group = group,
            callback = function()
                require("tablamd.edit").auto_align()
            end,
        })
    end
    if cfg.escape_pipes then
        api.nvim_create_autocmd("InsertCharPre", {
            buffer = buf,
            group = group,
            callback = function()
                require("tablamd.edit").escape_typed_pipe()
            end,
        })
    end
    if cfg.nowrap then
        api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufWinEnter" }, {
            buffer = buf,
            group = group,
            callback = function()
                local on_table = api.nvim_get_current_line():match("^%s*[|+]") ~= nil and M.in_table()
                if on_table and vim.w.tablamd_saved_wrap == nil then
                    vim.w.tablamd_saved_wrap = vim.wo.wrap
                    vim.opt_local.wrap = false
                elseif not on_table and vim.w.tablamd_saved_wrap ~= nil then
                    vim.opt_local.wrap = vim.w.tablamd_saved_wrap
                    vim.w.tablamd_saved_wrap = nil
                end
            end,
        })
    end
end

function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
    local group = api.nvim_create_augroup("tablamd", { clear = true })
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
