if vim.g.loaded_gridtable then
    return
end
vim.g.loaded_gridtable = true

-- :GridTable {action}, e.g. `:GridTable align`, `:'<,'>GridTable convert`
vim.api.nvim_create_user_command("GridTable", function(opts)
    local gt = require("gridtable")
    local name = opts.fargs[1]
    if not gt.actions[name] then
        return vim.notify("GridTable: unknown action " .. tostring(name), vim.log.levels.ERROR)
    end
    if (name == "convert" or name == "pandoc") and opts.range > 0 then
        return require("gridtable.convert").convert_range(opts.line1, opts.line2)
    end
    gt.call(name, opts.fargs[2] or 1) -- optional count: `:GridTable delete_row 3`
end, {
    nargs = "+",
    range = true,
    desc = "Grid table action",
    complete = function(lead, cmdline)
        if #vim.split(cmdline, "%s+", { trimempty = false }) > 2 then
            return {}
        end
        local names = vim.tbl_keys(require("gridtable").actions)
        table.sort(names)
        return vim.tbl_filter(function(n)
            return vim.startswith(n, lead)
        end, names)
    end,
})
