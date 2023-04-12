M = {}

local highlights_link = {
	["BetterVirtualTextError"] = "DiagnosticVirtualTextError",
	["BetterVirtualTextWarn"] = "DiagnosticVirtualTextWarn",
	["BetterVirtualTextInfo"] = "DiagnosticVirtualTextInfo",
	["BetterVirtualTextHint"] = "DiagnosticVirtualTextHint",
	["BetterVirtualTextPrefixError"] = "DiagnosticVirtualTextError",
	["BetterVirtualTextPrefixWarn"] = "DiagnosticVirtualTextWarn",
	["BetterVirtualTextPrefixInfo"] = "DiagnosticVirtualTextInfo",
	["BetterVirtualTextPrefixHint"] = "DiagnosticVirtualTextHint",
}

local function hl_exists(hl)
	local is_ok, hl_def = pcall(vim.api.nvim_get_hl_by_name, hl, true)
	return is_ok
end

local function setup_highlight_groups(highlights)
	for hl, link in pairs(highlights_link) do
		if highlights[hl] then
			vim.api.nvim_set_hl(0, hl, highlights[hl])
		elseif not hl_exists(hl) then
			vim.api.nvim_set_hl(0, hl, { link = link })
		end
	end
end

function M.setup(opts)
	setup_highlight_groups(opts.highlights)
	vim.diagnostic.handlers["better_virtual_text"] = require("handler")
end

return M
