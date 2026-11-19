if vim.g.loaded_tablamd then
    return
end
vim.g.loaded_tablamd = true

-- :TablaMd {action}, e.g. `:TablaMd align`, `:'<,'>TablaMd convert`
vim.api.nvim_create_user_command("TablaMd", function(opts)
    local gt = require("tablamd")
    local name = opts.fargs[1]
    if not gt.actions[name] then
        return vim.notify("TablaMd: unknown action " .. tostring(name), vim.log.levels.ERROR)
    end
    if (name == "convert" or name == "pandoc") and opts.range > 0 then
        return require("tablamd.convert").convert_range(opts.line1, opts.line2)
    end
    gt.call(name, opts.fargs[2] or 1) -- optional count: `:TablaMd delete_row 3`
end, {
    nargs = "+",
    range = true,
    desc = "Grid table action",
    complete = function(lead, cmdline)
        if #vim.split(cmdline, "%s+", { trimempty = false }) > 2 then
            return {}
        end
        local names = vim.tbl_keys(require("tablamd").actions)
        table.sort(names)
        return vim.tbl_filter(function(n)
            return vim.startswith(n, lead)
        end, names)
    end,
})
