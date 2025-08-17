local M = {}

-- Dependencies check
local deps = {}
for _, dep in ipairs({ "lspconfig", "plenary.path", "plenary.job" }) do
	local name = dep:match("([^.]+)")
	deps[name] = pcall(require, dep)
end

if not deps.lspconfig then
	vim.notify("docker_python_interpreter: nvim-lspconfig required", vim.log.levels.ERROR)
	return M
end

local lspconfig = require("lspconfig")
local util = require("lspconfig.util")
local Path = deps.plenary and require("plenary.path") or nil
local Job = deps.plenary and require("plenary.job") or nil

-- State Management ------------------------------------------------------------
M.state = {
	current = nil,
	opts = nil,
	cache = {
		venvs = nil,
		venvs_timestamp = 0,
		docker_available = nil,
		container_pyright = nil,
	},
	health = {
		last_check = 0,
		status = "unknown",
		details = {},
	},
}

-- Configuration defaults
M.defaults = {
	docker = {
		service = "web",
		workdir = "/srv/app",
		compose_cmd = { "docker", "compose" },
		path_map = { container_root = "/srv/app", host_root = nil },
		auto_install_pyright = true,
		pip_install_method = "auto", -- "auto", "system", "user", "break-system-packages"
		health_check_interval = 300, -- seconds
	},
	pyright_settings = {
		python = {
			analysis = {
				autoSearchPaths = true,
				diagnosticMode = "workspace",
				typeCheckingMode = "basic",
			},
		},
	},
	cache_ttl = 60, -- seconds for venv discovery cache
	auto_select = false, -- auto-select if only one option
	prefer_docker = false, -- prefer Docker over local when both available
	shim_log_file = nil, -- optional custom log file location
}

-- Utilities -------------------------------------------------------------------
local function merge_tables(...)
	local result = {}
	for _, t in ipairs({ ... }) do
		if type(t) == "table" then
			for k, v in pairs(t) do
				if type(v) == "table" and type(result[k]) == "table" then
					result[k] = merge_tables(result[k], v)
				else
					result[k] = v
				end
			end
		end
	end
	return result
end

local function project_root()
	local bufname = vim.api.nvim_buf_get_name(0)
	local root =
		util.root_pattern("pyproject.toml", "setup.cfg", "setup.py", "requirements.txt", "Pipfile", ".git")(bufname)
	return root or vim.fn.getcwd()
end

local function normalize_path(path)
	if Path then
		return Path:new(vim.fn.expand(path)):absolute()
	end
	return vim.fn.fnamemodify(vim.fn.expand(path), ":p")
end

local function ensure_dir(p)
	if vim.fn.isdirectory(p) == 0 then
		vim.fn.mkdir(p, "p")
	end
end

local function file_exists(path)
	return vim.fn.filereadable(path) == 1
end

local function is_executable(path)
	return vim.fn.executable(path) == 1
end

-- Get the plugin's runtime directory
local function get_plugin_dir()
	-- Try to find the plugin directory
	local runtime_paths = vim.api.nvim_list_runtime_paths()
	for _, path in ipairs(runtime_paths) do
		local test_path = path .. "/python/pyright_shim.py"
		if file_exists(test_path) then
			return path
		end
	end

	-- Fallback: assume we're in a standard plugin location
	local source = debug.getinfo(1, "S").source:sub(2) -- Remove @ prefix
	local plugin_root = vim.fn.fnamemodify(source, ":p:h:h")
	return plugin_root
end

-- Copy shim file to project directory (for Docker access)
local function setup_shim_file(host_root, container_root)
	local plugin_dir = get_plugin_dir()
	local source_shim = plugin_dir .. "/python/pyright_shim.py"

	-- Check if source exists
	if not file_exists(source_shim) then
		vim.notify("ERROR: pyright_shim.py not found in plugin directory", vim.log.levels.ERROR)
		vim.notify("Looking for: " .. source_shim, vim.log.levels.ERROR)
		return nil
	end

	-- Create .nvim directory in project
	local shim_dir = host_root .. "/.nvim"
	ensure_dir(shim_dir)

	-- Copy shim to project directory
	local dest_shim = shim_dir .. "/pyright_shim.py"

	-- Read source file
	local source_content = vim.fn.readfile(source_shim)

	-- Write to destination
	vim.fn.writefile(source_content, dest_shim)
	vim.fn.setfperm(dest_shim, "rwxr-xr-x")

	vim.notify("Shim script copied to: " .. dest_shim, vim.log.levels.DEBUG)

	return dest_shim
end

-- Docker utilities ------------------------------------------------------------
local function check_docker_available()
	if M.state.cache.docker_available ~= nil then
		return M.state.cache.docker_available
	end

	local compose_cmd = M.state.opts.docker.compose_cmd
	local check_cmd = vim.list_extend(vim.deepcopy(compose_cmd), { "version" })
	local result = vim.fn.system(check_cmd)
	M.state.cache.docker_available = vim.v.shell_error == 0

	return M.state.cache.docker_available
end

local function check_container_running(service)
	local cmd = vim.list_extend(vim.deepcopy(M.state.opts.docker.compose_cmd), { "ps", "-q", service })
	local result = vim.fn.system(cmd)
	return vim.v.shell_error == 0 and result ~= ""
end

local function check_pyright_in_container(service)
	if M.state.cache.container_pyright ~= nil then
		return M.state.cache.container_pyright
	end

	local cmd = vim.list_extend(vim.deepcopy(M.state.opts.docker.compose_cmd), {
		"exec",
		"-T",
		service,
		"python",
		"-c",
		"import sys; import importlib.util; sys.exit(0 if importlib.util.find_spec('pyright') else 1)",
	})

	vim.fn.system(cmd)
	M.state.cache.container_pyright = vim.v.shell_error == 0
	return M.state.cache.container_pyright
end

local function install_pyright_in_container(service)
	vim.notify("Installing Pyright in container...", vim.log.levels.INFO)

	local install_methods = {}
	local pip_method = M.state.opts.docker.pip_install_method or "auto"

	if pip_method == "auto" then
		-- Try multiple methods automatically
		install_methods = {
			{ "python", "-m", "pip", "install", "pyright" }, -- Standard install
			{ "python", "-m", "pip", "install", "--user", "pyright" }, -- User install
			{ "python", "-m", "pip", "install", "--break-system-packages", "pyright" }, -- Force install
		}
	elseif pip_method == "system" then
		install_methods = { { "python", "-m", "pip", "install", "pyright" } }
	elseif pip_method == "user" then
		install_methods = { { "python", "-m", "pip", "install", "--user", "pyright" } }
	elseif pip_method == "break-system-packages" then
		install_methods = { { "python", "-m", "pip", "install", "--break-system-packages", "pyright" } }
	end

	for i, install_args in ipairs(install_methods) do
		local cmd = vim.deepcopy(M.state.opts.docker.compose_cmd)
		vim.list_extend(cmd, { "exec", "-T", service })
		vim.list_extend(cmd, install_args)

		local result = vim.fn.system(cmd)
		if vim.v.shell_error == 0 then
			M.state.cache.container_pyright = true
			vim.notify(
				"Pyright installed successfully" .. (pip_method == "auto" and " (method " .. i .. ")" or ""),
				vim.log.levels.INFO
			)
			return true
		end
	end

	vim.notify(
		"Failed to install Pyright in container. Please install manually:\n"
			.. "docker compose exec "
			.. service
			.. " pip install pyright",
		vim.log.levels.ERROR
	)
	return false
end

-- Interpreter discovery -------------------------------------------------------
local function discover_local_venvs()
	local now = os.time()
	if M.state.cache.venvs and (now - M.state.cache.venvs_timestamp) < M.state.opts.cache_ttl then
		return M.state.cache.venvs
	end

	local root = project_root()
	local candidates = {}

	-- Common virtual environment locations
	local venv_patterns = {
		".venv/bin/python",
		"venv/bin/python",
		"env/bin/python",
		".env/bin/python",
		"virtualenv/bin/python",
	}

	for _, pattern in ipairs(venv_patterns) do
		local path = root .. "/" .. pattern
		if is_executable(path) then
			table.insert(candidates, normalize_path(path))
		end
	end

	-- Check for Poetry environments
	local poetry_env = vim.fn.system("poetry env info --path 2>/dev/null")
	if vim.v.shell_error == 0 and poetry_env ~= "" then
		local poetry_python = vim.trim(poetry_env) .. "/bin/python"
		if is_executable(poetry_python) then
			table.insert(candidates, normalize_path(poetry_python))
		end
	end

	-- Check for Pipenv
	local pipenv_python = vim.fn.system("pipenv --py 2>/dev/null")
	if vim.v.shell_error == 0 and pipenv_python ~= "" then
		local path = vim.trim(pipenv_python)
		if is_executable(path) then
			table.insert(candidates, normalize_path(path))
		end
	end

	-- Remove duplicates
	local seen = {}
	local unique = {}
	for _, path in ipairs(candidates) do
		if not seen[path] then
			seen[path] = true
			table.insert(unique, path)
		end
	end

	M.state.cache.venvs = unique
	M.state.cache.venvs_timestamp = now
	return unique
end

-- LSP management --------------------------------------------------------------
local function build_docker_cmd(opts)
	local host = opts.path_map and opts.path_map.host_root or project_root()
	local container = opts.path_map and opts.path_map.container_root or opts.workdir

	host = normalize_path(host)
	local shim_path = setup_shim_file(host, container)

	if not shim_path then
		vim.notify("Failed to setup shim script", vim.log.levels.ERROR)
		return nil
	end

	local cmd = vim.deepcopy(opts.compose_cmd or { "docker", "compose" })
	vim.list_extend(cmd, {
		"exec",
		"-T",
		"-w",
		opts.workdir,
		"-e",
		"HOST_ROOT=" .. host,
		"-e",
		"CONTAINER_ROOT=" .. container,
	})

	-- Add debug flag if needed
	if vim.env.DEBUG_DOCKER_PYTHON then
		table.insert(cmd, "-e")
		table.insert(cmd, "DEBUG_SHIM=1")
	end

	-- Optional: custom log file location
	if M.state.opts.shim_log_file then
		local log_path = normalize_path(M.state.opts.shim_log_file)
		-- If the log path is within the host project root, map it to container path
		if vim.startswith(log_path, host) then
			log_path = log_path:gsub(vim.pesc(host), container)
		end
		table.insert(cmd, "-e")
		table.insert(cmd, "SHIM_LOG_FILE=" .. log_path)
	end

	vim.list_extend(cmd, {
		opts.service,
		"python",
		shim_path:gsub(vim.pesc(host), container),
	})

	vim.notify("docker pyright cmd: " .. table.concat(cmd, " "), vim.log.levels.DEBUG)

	return cmd
end

local function build_local_cmd(python_bin)
	return { python_bin, "-m", "pyright", "--stdio" }
end

local function stop_pyright()
	for _, client in ipairs(vim.lsp.get_active_clients()) do
		if client.name == "pyright" or client.name == "pyright_docker" then
			client.stop(true)
		end
	end
end

local function start_pyright(cmd, settings)
	stop_pyright()

	-- Use a dedicated server name to avoid conflicts with user-configured pyright
	local server_name = "pyright_docker"
	local configs = require("lspconfig.configs")
	local new_config = {
		cmd = cmd,
		filetypes = { "python" },
		root_dir = function(fname)
			return util.find_git_ancestor(fname) or project_root()
		end,
		settings = settings or {},
		on_init = function(client)
			vim.notify("Pyright Docker LSP initialized", vim.log.levels.DEBUG)
		end,
		on_attach = function(client, bufnr)
			if M.state.opts.on_attach then
				M.state.opts.on_attach(client, bufnr)
			end
		end,
	}

	if not configs[server_name] then
		configs[server_name] = { default_config = new_config }
	else
		configs[server_name].default_config = new_config
	end

	lspconfig[server_name].setup(new_config)

	vim.notify("Starting Pyright (docker) with command: " .. table.concat(cmd, " "), vim.log.levels.DEBUG)

	-- Restart for current Python buffers
	vim.defer_fn(function()
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "python" then
				vim.api.nvim_buf_call(buf, function()
					vim.cmd("LspStop pyright")
					vim.cmd("LspStart " .. server_name)
				end)
			end
		end
	end, 100)
end

-- Health check system ---------------------------------------------------------
function M.health_check()
	local health = {
		status = "healthy",
		details = {},
		timestamp = os.time(),
	}

	-- Check current interpreter
	if not M.state.current then
		health.status = "unconfigured"
		health.details.interpreter = "No interpreter selected"
	elseif M.state.current.kind == "docker" then
		-- Check Docker health
		if not check_docker_available() then
			health.status = "unhealthy"
			health.details.docker = "Docker not available"
		elseif not check_container_running(M.state.current.opts.service) then
			health.status = "unhealthy"
			health.details.container = "Container not running"
		elseif not check_pyright_in_container(M.state.current.opts.service) then
			health.status = "degraded"
			health.details.pyright = "Pyright not installed in container"
		end
	elseif M.state.current.kind == "venv" then
		-- Check venv health
		if not is_executable(M.state.current.python) then
			health.status = "unhealthy"
			health.details.python = "Python binary not found"
		end
	end

	-- Check LSP client
	local active = false
	for _, client in ipairs(vim.lsp.get_active_clients()) do
		if client.name == "pyright" or client.name == "pyright_docker" then
			active = true
			break
		end
	end
	if not active then
		health.status = health.status == "healthy" and "degraded" or health.status
		health.details.lsp = "Pyright LSP not running"
	end

	M.state.health = health
	return health
end

-- Public API ------------------------------------------------------------------
function M.setup(opts)
	M.state.opts = merge_tables(M.defaults, opts or {})

	-- Pre-register docker-backed Pyright server so it shows in :LspInfo
	local configs = require("lspconfig.configs")
	if not configs.pyright_docker then
		configs.pyright_docker = {
			default_config = {
				cmd = { "pyright-langserver", "--stdio" },
				filetypes = { "python" },
				root_dir = function(fname)
					return util.find_git_ancestor(fname) or project_root()
				end,
				settings = M.state.opts.pyright_settings or {},
			},
		}
	end

	-- Create user commands
	vim.api.nvim_create_user_command("SelectPythonInterpreter", function()
		M.select_interpreter()
	end, { desc = "Select Python interpreter for Pyright LSP" })

	vim.api.nvim_create_user_command("PythonInterpreterInfo", function()
		local info = {
			current = M.state.current,
			health = M.health_check(),
		}
		vim.notify(vim.inspect(info), vim.log.levels.INFO)
	end, { desc = "Show current Python interpreter info" })

	vim.api.nvim_create_user_command("PythonInterpreterHealth", function()
		local health = M.health_check()
		local level = health.status == "healthy" and vim.log.levels.INFO or vim.log.levels.WARN
		vim.notify("Health: " .. health.status .. "\n" .. vim.inspect(health.details), level)
	end, { desc = "Check Python interpreter health" })

	vim.api.nvim_create_user_command("RestartPyright", function()
		if not M.state.current then
			vim.notify("No interpreter selected", vim.log.levels.WARN)
			return
		end
		M.restart_with_current()
	end, { desc = "Restart Pyright with current interpreter" })

	-- Auto-select if configured
	if M.state.opts.auto_select then
		vim.defer_fn(function()
			M.auto_select()
		end, 100)
	end

	-- Set up health check timer if configured
	if M.state.opts.docker.health_check_interval > 0 then
		vim.fn.timer_start(M.state.opts.docker.health_check_interval * 1000, function()
			local health = M.health_check()
			if health.status == "unhealthy" then
				vim.notify("Python interpreter unhealthy: " .. vim.inspect(health.details), vim.log.levels.WARN)
			end
		end, { ["repeat"] = -1 })
	end
end

function M.select_interpreter()
	local choices = {}
	local items = {}

	-- Check Docker availability
	if check_docker_available() then
		local docker_label = string.format("Docker: %s (Pyright in container)", M.state.opts.docker.service)
		if check_container_running(M.state.opts.docker.service) then
			table.insert(choices, docker_label)
			table.insert(items, { kind = "docker", opts = M.state.opts.docker })
		else
			table.insert(choices, docker_label .. " [container not running]")
			table.insert(items, { kind = "docker_unavailable" })
		end
	end

	-- Local venvs
	local venvs = discover_local_venvs()
	for _, path in ipairs(venvs) do
		local display = path:gsub("^" .. vim.pesc(project_root()) .. "/", "")
		table.insert(choices, "Local: " .. display)
		table.insert(items, { kind = "venv", python = path })
	end

	-- System Python
	if is_executable("python3") then
		table.insert(choices, "System: python3")
		table.insert(items, { kind = "venv", python = "python3" })
	end

	-- Manual entry
	table.insert(choices, "Enter Python path manually...")
	table.insert(items, { kind = "manual" })

	vim.ui.select(choices, {
		prompt = "Select Python Interpreter",
		format_item = function(item)
			return item
		end,
	}, function(choice, idx)
		if not choice or not idx then
			return
		end

		local selected = items[idx]

		if selected.kind == "docker_unavailable" then
			vim.notify("Container is not running. Please start it first.", vim.log.levels.ERROR)
			return
		elseif selected.kind == "manual" then
			vim.ui.input({
				prompt = "Python binary path: ",
				default = "python3",
				completion = "file",
			}, function(input)
				if not input or #input == 0 then
					return
				end
				M.activate_interpreter({ kind = "venv", python = input })
			end)
			return
		end

		M.activate_interpreter(selected)
	end)
end

function M.activate_interpreter(interpreter)
	if interpreter.kind == "docker" then
		-- Ensure container has Pyright
		if not check_pyright_in_container(interpreter.opts.service) then
			if M.state.opts.docker.auto_install_pyright then
				if not install_pyright_in_container(interpreter.opts.service) then
					return
				end
			else
				vim.notify(
					"Pyright not found in container. Install it or enable auto_install_pyright",
					vim.log.levels.ERROR
				)
				return
			end
		end

		M.state.current = {
			kind = "docker",
			opts = interpreter.opts,
			settings = M.state.opts.pyright_settings,
		}
		local cmd = build_docker_cmd(interpreter.opts)
		if not cmd then
			vim.notify("Failed to build Docker command", vim.log.levels.ERROR)
			return
		end
		start_pyright(cmd, M.state.opts.pyright_settings)
		vim.notify("Switched to Docker: " .. interpreter.opts.service, vim.log.levels.INFO)
	elseif interpreter.kind == "venv" then
		if not is_executable(interpreter.python) then
			vim.notify("Python binary not found: " .. interpreter.python, vim.log.levels.ERROR)
			return
		end

		M.state.current = {
			kind = "venv",
			python = interpreter.python,
			settings = M.state.opts.pyright_settings,
		}
		start_pyright(build_local_cmd(interpreter.python), M.state.opts.pyright_settings)
		vim.notify("Switched to: " .. interpreter.python, vim.log.levels.INFO)
	end
end

function M.restart_with_current()
	if not M.state.current then
		vim.notify("No interpreter selected", vim.log.levels.WARN)
		return
	end

	M.activate_interpreter(M.state.current)
	vim.notify("Pyright restarted", vim.log.levels.INFO)
end

function M.auto_select()
	local docker_available = check_docker_available() and check_container_running(M.state.opts.docker.service)
	local venvs = discover_local_venvs()

	if M.state.opts.prefer_docker and docker_available then
		M.activate_interpreter({ kind = "docker", opts = M.state.opts.docker })
	elseif #venvs == 1 and not docker_available then
		M.activate_interpreter({ kind = "venv", python = venvs[1] })
	elseif #venvs == 0 and docker_available then
		M.activate_interpreter({ kind = "docker", opts = M.state.opts.docker })
	end
end

return M
