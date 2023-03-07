local api = vim.api
local fn = vim.fn

local highlight  = require('ufo.highlight')
local extmark    = require('ufo.render.extmark')
local treesitter = require('ufo.render.treesitter')
local match      = require('ufo.render.match')
local utils      = require('ufo.utils')

local M = {}

local function fillSlots(mark, len, hlGroups, hlGroupSlots, prioritySlots)
    local col, endCol, hlGroup, priority = mark[2], mark[4], mark[5], mark[6]
    if not hlGroup or not hlGroups[hlGroup].foreground then
        return
    end
    if endCol == -1 then
        endCol = len
    end
    for i = col + 1, endCol do
        local oldPriority = prioritySlots[i]
        if not oldPriority or oldPriority <= priority then
            prioritySlots[i] = priority
            hlGroupSlots[i] = hlGroup
        end
    end
end

-- 1-indexed
local function syntaxToRowHighlightRange(res, lnum, startCol, endCol)
    local lastIndex = 1
    local lastHlId
    for c = startCol, endCol do
        local hlId = fn.synID(lnum, c, true)
        if lastHlId and lastHlId ~= hlId then
            table.insert(res, {lnum, lastIndex, c - 1, lastHlId})
            lastIndex = c
        end
        lastHlId = hlId
    end
    table.insert(res, {lnum, lastIndex, endCol, lastHlId})
end

local function mapMarkers(bufnr, startRow, marks, hlGroups, ns)
    for _, m in ipairs(marks) do
        if next(hlGroups[m[5]]) then
            m[1] = m[1] - startRow
            m[3] = m[3] - startRow
            extmark.setHighlight(bufnr, ns, m[1], m[2], m[3], m[4], m[5], m[6])
        end
    end
end

function M.mapHighlightLimitByRange(srcBufnr, dstBufnr, startRange, endRange, text, ns)
    local startRow, startCol = startRange[1], startRange[1]
    local endRow, endCol = endRange[1], endRange[2]
    local nss = {}
    for _, namespace in pairs(api.nvim_get_namespaces()) do
        if ns ~= namespace then
            table.insert(nss, namespace)
        end
    end
    local hlGroups = highlight.hlGroups()
    local marks = extmark.getHighlightsByRange(srcBufnr, startRange, endRange, nss)
    mapMarkers(dstBufnr, startRow, marks, hlGroups, ns)
    marks = treesitter.getHighlightsByRange(srcBufnr, startRange, endRange, hlGroups)
    mapMarkers(dstBufnr, startRow, marks, hlGroups, ns)
    if vim.bo[srcBufnr].syntax ~= '' then
        api.nvim_buf_call(srcBufnr, function()
            local res = {}
            local lnum, endLnum = startRow + 1, endRow + 1
            if lnum == endLnum then
                syntaxToRowHighlightRange(res, lnum, startCol + 1, endCol)
            else
                for l = lnum, endLnum - 1 do
                    syntaxToRowHighlightRange(res, l, 1, #text[l - lnum + 1])
                end
                syntaxToRowHighlightRange(res, endLnum, 1, endCol)
            end
            for _, r in ipairs(res) do
                local row = r[1] - lnum
                extmark.setHighlight(dstBufnr, ns, row, r[2] - 1, row, r[3], r[4], 1)
            end
        end)
    end
end

function M.mapMatchByLnum(srcWinid, dstWinid, lnum, endLnum)
    local res = match.mapHighlightsByLnum(srcWinid, lnum, endLnum)
    if not vim.tbl_isempty(res) then
        fn.setmatches(res, dstWinid)
    end
end

function M.setVirtText(bufnr, ns, row, virtText, opts)
    return extmark.setVirtText(bufnr, ns, row, virtText, opts)
end

function M.captureVirtText(bufnr, text, lnum, syntax, namespaces)
    local len = #text
    if len == 0 then
        return {{'', 'UfoFoldedFg'}}
    end
    local prioritySlots = {}
    local hlGroupSlots = {}
    local marks = extmark.getHighlightsByRange(bufnr, {lnum - 1, 0}, {lnum - 1, len}, namespaces)
    local hlGroups = highlight.hlGroups()
    for _, m in ipairs(marks) do
        fillSlots(m, len, hlGroups, hlGroupSlots, prioritySlots)
    end
    marks = treesitter.getHighlightsByRange(bufnr, {lnum - 1, 0}, {lnum - 1, len})
    for _, m in ipairs(marks) do
        fillSlots(m, len, hlGroups, hlGroupSlots, prioritySlots)
    end
    if syntax then
        api.nvim_buf_call(bufnr, function()
            for i = 1, len do
                if not prioritySlots[i] then
                    local hlId = fn.synID(lnum, i, true)
                    prioritySlots[i] = 1
                    hlGroupSlots[i] = hlId
                end
            end
        end)
    end
    local virtText = {}
    -- local lastHlGroup = hlGroupSlots[1] or 'UfoFoldedFg'
    local lastHlGroup = 'UfoFoldedFg'
    local lastIndex = 1
    for i = 2, len do
        -- local hlGroup = hlGroupSlots[i] or 'UfoFoldedFg'
        local hlGroup = 'UfoFoldedFg'
        if lastHlGroup ~= hlGroup then
            table.insert(virtText, {text:sub(lastIndex, i - 1), lastHlGroup})
            lastIndex = i
            lastHlGroup = hlGroup
        end
    end
    table.insert(virtText, {text:sub(lastIndex), lastHlGroup})
    return virtText
end

---Prefer use nvim_buf_set_extmark rather than matchaddpos, only use matchaddpos if buffer is shared
---with multiple windows in current tabpage.
---Check out https://github.com/neovim/neovim/issues/20208 for detail.
---@param handle number
---@param hlGroup string
---@param ns number
---@param start number
---@param finish number
---@param delay? number
---@param shared? boolean
---@return Promise
function M.highlightLinesWithTimeout(handle, hlGroup, ns, start, finish, delay, shared)
    vim.validate({
        handle = {handle, 'number'},
        hlGoup = {hlGroup, 'string'},
        ns = {ns, 'number'},
        start = {start, 'number'},
        finish = {finish, 'number'},
        delay = {delay, 'number', true},
        shared = {shared, 'boolean', true},
    })
    local ids = {}
    local onFulfilled
    if shared then
        local prior = 10
        local l = {}
        for i = start, finish do
            table.insert(l, {i})
            if i % 8 == 0 then
                table.insert(ids, fn.matchaddpos(hlGroup, l, prior))
                l = {}
            end
        end
        if #l > 0 then
            table.insert(ids, fn.matchaddpos(hlGroup, l, prior))
        end
        onFulfilled = function()
            for _, id in ipairs(ids) do
                pcall(fn.matchdelete, id, handle)
            end
        end
    else
        local o = {hl_group = hlGroup}
        for i = start, finish do
            local row, col = i - 1, 0
            o.end_row = i
            o.end_col = 0
            table.insert(ids, api.nvim_buf_set_extmark(handle, ns, row, col, o))
        end
        onFulfilled = function()
            for _, id in ipairs(ids) do
                pcall(api.nvim_buf_del_extmark, handle, ns, id)
            end
        end
    end
    return utils.wait(delay or 300):thenCall(onFulfilled)
end

return M
