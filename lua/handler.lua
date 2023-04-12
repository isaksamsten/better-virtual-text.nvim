local api = vim.api
local diagnostic_cache
do
	local group = api.nvim_create_augroup("BetterVirtualTextBufWipeout", {})
	diagnostic_cache = setmetatable({}, {
		__index = function(t, bufnr)
			assert(bufnr > 0, "Invalid buffer number")
			api.nvim_create_autocmd("BufWipeout", {
				group = group,
				buffer = bufnr,
				callback = function()
					rawset(t, bufnr, nil)
				end,
			})
			t[bufnr] = {}
			return t[bufnr]
		end,
	})
end

local bufnr_and_namespace_cacher_mt = {
	__index = function(t, bufnr)
		assert(bufnr > 0, "Invalid buffer number")
		t[bufnr] = {}
		return t[bufnr]
	end,
}

local diagnostic_severities = {
	[vim.diagnostic.severity.ERROR] = "Error",
	[vim.diagnostic.severity.WARN] = "Warn",
	[vim.diagnostic.severity.INFO] = "Info",
	[vim.diagnostic.severity.HINT] = "Hint",
}
local function make_highlight_map(base_name)
	local result = {}
	for k in pairs(diagnostic_severities) do
		local name = vim.diagnostic.severity[k]
		name = name:sub(1, 1) .. name:sub(2):lower()
		result[k] = base_name .. name
	end

	return result
end

local virtual_text_highlight_map = make_highlight_map("BetterVirtualText")
local virtual_text_prefix_highlight_map = make_highlight_map("BetterVirtualTextPrefix")

local diagnostic_cache_extmarks = setmetatable({}, bufnr_and_namespace_cacher_mt)
local diagnostic_attached_buffers = {}

---@private
local function get_bufnr(bufnr)
	if not bufnr or bufnr == 0 then
		return api.nvim_get_current_buf()
	end
	return bufnr
end

---@private
local function reformat_diagnostics(format, diagnostics)
	vim.validate({
		format = { format, "f" },
		diagnostics = { diagnostics, "t" },
	})

	local formatted = vim.deepcopy(diagnostics)
	for _, diagnostic in ipairs(formatted) do
		diagnostic.message = format(diagnostic)
	end
	return formatted
end

---@private
local function count_sources(bufnr)
	local seen = {}
	local count = 0
	for _, namespace_diagnostics in pairs(diagnostic_cache[bufnr]) do
		for _, diagnostic in ipairs(namespace_diagnostics) do
			if diagnostic.source and not seen[diagnostic.source] then
				seen[diagnostic.source] = true
				count = count + 1
			end
		end
	end
	return count
end

---@private
local function prefix_source(diagnostics)
	return vim.tbl_map(function(d)
		if not d.source then
			return d
		end

		local t = vim.deepcopy(d)
		t.message = string.format("%s: %s", d.source, d.message)
		return t
	end, diagnostics)
end

---@private
local function diagnostic_lines(diagnostics)
	if not diagnostics then
		return {}
	end

	local diagnostics_by_line = {}
	for _, diagnostic in ipairs(diagnostics) do
		local line_diagnostics = diagnostics_by_line[diagnostic.lnum]
		if not line_diagnostics then
			line_diagnostics = {}
			diagnostics_by_line[diagnostic.lnum] = line_diagnostics
		end
		table.insert(line_diagnostics, diagnostic)
	end
	return diagnostics_by_line
end

---@private
local function to_severity(severity)
	if type(severity) == "string" then
		return assert(M.severity[string.upper(severity)], string.format("Invalid severity: %s", severity))
	end
	return severity
end

---@private
local function filter_by_severity(severity, diagnostics)
	if not severity then
		return diagnostics
	end

	if type(severity) ~= "table" then
		severity = to_severity(severity)
		return vim.tbl_filter(function(t)
			return t.severity == severity
		end, diagnostics)
	end

	local min_severity = to_severity(severity.min) or M.severity.HINT
	local max_severity = to_severity(severity.max) or M.severity.ERROR

	return vim.tbl_filter(function(t)
		return t.severity <= min_severity and t.severity >= max_severity
	end, diagnostics)
end

---@private
local function restore_extmarks(bufnr, last)
	for ns, extmarks in pairs(diagnostic_cache_extmarks[bufnr]) do
		local extmarks_current = api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
		local found = {}
		for _, extmark in ipairs(extmarks_current) do
			-- nvim_buf_set_lines will move any extmark to the line after the last
			-- nvim_buf_set_text will move any extmark to the last line
			if extmark[2] ~= last + 1 then
				found[extmark[1]] = true
			end
		end
		for _, extmark in ipairs(extmarks) do
			if not found[extmark[1]] then
				local opts = extmark[4]
				opts.id = extmark[1]
				pcall(api.nvim_buf_set_extmark, bufnr, ns, extmark[2], extmark[3], opts)
			end
		end
	end
end

---@private
local function save_extmarks(namespace, bufnr)
	bufnr = get_bufnr(bufnr)
	if not diagnostic_attached_buffers[bufnr] then
		api.nvim_buf_attach(bufnr, false, {
			on_lines = function(_, _, _, _, _, last)
				restore_extmarks(bufnr, last - 1)
			end,
			on_detach = function()
				diagnostic_cache_extmarks[bufnr] = nil
			end,
		})
		diagnostic_attached_buffers[bufnr] = true
	end
	diagnostic_cache_extmarks[bufnr][namespace] = api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })
end

M = {}
function M.show(namespace, bufnr, diagnostics, opts)
	vim.validate({
		namespace = { namespace, "n" },
		bufnr = { bufnr, "n" },
		diagnostics = {
			diagnostics,
			vim.tbl_islist,
			"a list of diagnostics",
		},
		opts = { opts, "t", true },
	})
	bufnr = get_bufnr(bufnr)
	opts = opts or {}

	local severity
	if opts.virtual_text then
		if opts.virtual_text.format then
			diagnostics = reformat_diagnostics(opts.virtual_text.format, diagnostics)
		end
		if opts.virtual_text.source and (opts.virtual_text.source ~= "if_many" or count_sources(bufnr) > 1) then
			diagnostics = prefix_source(diagnostics)
		end
		if opts.virtual_text.severity then
			severity = opts.virtual_text.severity
		end
	end

	local ns = vim.diagnostic.get_namespace(namespace)
	if not ns.user_data.virt_text_ns then
		ns.user_data.virt_text_ns = api.nvim_create_namespace("")
	end

	local virt_text_ns = ns.user_data.virt_text_ns
	local buffer_line_diagnostics = diagnostic_lines(diagnostics)
	for line, line_diagnostics in pairs(buffer_line_diagnostics) do
		if severity then
			line_diagnostics = filter_by_severity(severity, line_diagnostics)
		end
		local virt_texts = M._get_virt_text_chunks(line_diagnostics, opts.better_virtual_text or opts.virtual_text)

		if virt_texts then
			api.nvim_buf_set_extmark(bufnr, virt_text_ns, line, 0, {
				hl_mode = "combine",
				virt_text = virt_texts,
			})
		end
	end
	save_extmarks(virt_text_ns, bufnr)
end
function M.hide(namespace, bufnr)
	local ns = vim.diagnostic.get_namespace(namespace)
	if ns.user_data.virt_text_ns then
		diagnostic_cache_extmarks[bufnr][ns.user_data.virt_text_ns] = {}
		if api.nvim_buf_is_valid(bufnr) then
			api.nvim_buf_clear_namespace(bufnr, ns.user_data.virt_text_ns, 0, -1)
		end
	end
end

function M._get_virt_text_chunks(line_diags, opts)
	if #line_diags == 0 then
		return nil
	end

	opts = opts or {}
	local prefix = opts.prefix or "■"
	local suffix = opts.suffix or ""
	local spacing = opts.spacing or 4

	-- Create a little more space between virtual text and contents
	local virt_texts = { { string.rep(" ", spacing) } }

	for i = 1, #line_diags do
		local resolved_prefix = prefix
		if type(prefix) == "function" then
			resolved_prefix = prefix(line_diags[i]) or ""
		end
		table.insert(virt_texts, { resolved_prefix, virtual_text_prefix_highlight_map[line_diags[i].severity] })
	end
	local last = line_diags[#line_diags]

	-- TODO(tjdevries): Allow different servers to be shown first somehow?
	-- TODO(tjdevries): Display server name associated with these?
	if last.message then
		if type(suffix) == "function" then
			suffix = suffix(last) or ""
		end
		table.insert(virt_texts, {
			string.format(" %s%s", last.message:gsub("\r", ""):gsub("\n", "  "), suffix),
			virtual_text_highlight_map[last.severity],
		})

		return virt_texts
	end
end

return M
