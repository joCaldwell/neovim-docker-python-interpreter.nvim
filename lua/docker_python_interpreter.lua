-- neovim-docker-python-interpreter.nvim
-- Author: joCaldwell
-- License: MIT

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
		return Path:new(path):make_absolute()
	end
	return vim.fn.fnamemodify(path, ":p")
end

local function ensure_dir(p)
	if vim.fn.isdirectory(p) == 0 then
		vim.fn.mkdir(p, "p")
	end
end

local function is_executable(path)
	return vim.fn.executable(path) == 1
end

-- Enhanced shim with better error handling
local function write_shim_file(host_root, container_root)
	local shim_dir = host_root .. "/.nvim"
	ensure_dir(shim_dir)
	local shim_path = shim_dir .. "/docker_pyright_shim.py"

	local shim = [[#!/usr/bin/env python3
"""Enhanced JSON-RPC path rewrite shim for Docker Pyright integration."""
import json
import os
import sys
import subprocess
import threading
import traceback
import logging
from pathlib import Path
from typing import Any, Dict, Optional

# Configure logging
logging.basicConfig(
    level=logging.DEBUG if os.environ.get("DEBUG_SHIM") else logging.WARNING,
    format='[%(asctime)s] %(levelname)s: %(message)s',
    handlers=[logging.FileHandler('/tmp/pyright_shim.log'), logging.StreamHandler(sys.stderr)]
)
logger = logging.getLogger(__name__)

HOST_ROOT = os.environ.get("HOST_ROOT", "/work/host")
CONTAINER_ROOT = os.environ.get("CONTAINER_ROOT", "/work/container")

# Normalize paths
HOST_ROOT = str(Path(HOST_ROOT).resolve())
CONTAINER_ROOT = str(Path(CONTAINER_ROOT).resolve())

logger.info(f"Path mapping: {HOST_ROOT} <-> {CONTAINER_ROOT}")

class PathRewriter:
    """Handles bidirectional path rewriting."""
    
    PATH_KEYS = {
        "uri", "targetUri", "source", "file", "path",
        "rootPath", "rootUri", "workspaceFolders",
        "documentUri", "newUri", "oldUri"
    }
    
    @staticmethod
    def rewrite_path(s: Any, from_prefix: str, to_prefix: str) -> Any:
        """Rewrite a single path string."""
        if not isinstance(s, str):
            return s
        
        # Handle file:// URIs
        if s.startswith("file://"):
            path = s[7:]
            # Handle percent-encoded paths
            if '%' in path:
                from urllib.parse import unquote
                path = unquote(path)
            
            if path.startswith(from_prefix):
                new_path = to_prefix + path[len(from_prefix):]
                return "file://" + new_path
            return s
        
        # Handle absolute paths
        if s.startswith(from_prefix):
            return to_prefix + s[len(from_prefix):]
        
        return s
    
    @classmethod
    def rewrite_obj(cls, obj: Any, from_prefix: str, to_prefix: str) -> Any:
        """Recursively rewrite paths in object."""
        if isinstance(obj, dict):
            result = {}
            for k, v in obj.items():
                if k in cls.PATH_KEYS:
                    result[k] = cls.rewrite_path(v, from_prefix, to_prefix)
                elif k == "workspaceFolders" and isinstance(v, list):
                    # Special handling for workspace folders
                    result[k] = [cls.rewrite_obj(item, from_prefix, to_prefix) for item in v]
                else:
                    result[k] = cls.rewrite_obj(v, from_prefix, to_prefix)
            return result
        elif isinstance(obj, list):
            return [cls.rewrite_obj(item, from_prefix, to_prefix) for item in obj]
        elif isinstance(obj, str):
            # Check if this looks like a path even if not in expected keys
            if (obj.startswith(from_prefix) or obj.startswith("file://")):
                return cls.rewrite_path(obj, from_prefix, to_prefix)
        return obj

class JsonRpcProxy:
    """JSON-RPC message proxy with path rewriting."""
    
    def __init__(self):
        self.rewriter = PathRewriter()
        self.child = None
        self.start_server()
    
    def start_server(self):
        """Start the Pyright language server."""
        try:
            self.child = subprocess.Popen(
                [sys.executable, "-m", "pyright", "--stdio"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=False,  # Use binary mode for better control
                bufsize=0
            )
            logger.info("Pyright server started successfully")
            
            # Start stderr pump thread
            threading.Thread(target=self.pump_stderr, daemon=True).start()
        except Exception as e:
            logger.error(f"Failed to start Pyright: {e}")
            sys.exit(1)
    
    def pump_stderr(self):
        """Forward stderr from child process."""
        try:
            for line in self.child.stderr:
                sys.stderr.buffer.write(line)
                sys.stderr.buffer.flush()
        except Exception as e:
            logger.error(f"Error pumping stderr: {e}")
    
    def read_message(self, stream) -> Optional[Dict]:
        """Read a JSON-RPC message from stream."""
        try:
            headers = {}
            while True:
                line = stream.readline()
                if not line:
                    return None
                if line == b"\r\n":
                    break
                if b":" in line:
                    key, value = line.decode('utf-8').split(":", 1)
                    headers[key.strip().lower()] = value.strip()
            
            content_length = int(headers.get("content-length", 0))
            if content_length == 0:
                logger.warning("No content-length header found")
                return None
            
            body = stream.read(content_length)
            return json.loads(body.decode('utf-8'))
        except Exception as e:
            logger.error(f"Error reading message: {e}")
            return None
    
    def write_message(self, stream, obj: Dict):
        """Write a JSON-RPC message to stream."""
        try:
            content = json.dumps(obj, separators=(",", ":"))
            content_bytes = content.encode('utf-8')
            header = f"Content-Length: {len(content_bytes)}\r\n\r\n"
            stream.write(header.encode('utf-8'))
            stream.write(content_bytes)
            stream.flush()
        except Exception as e:
            logger.error(f"Error writing message: {e}")
    
    def run(self):
        """Main proxy loop."""
        logger.info("Starting proxy loop")
        
        while True:
            try:
                # Read from client (Neovim)
                msg = self.read_message(sys.stdin.buffer)
                if msg is None:
                    logger.info("Client disconnected")
                    break
                
                # Log request type for debugging
                method = msg.get("method", "")
                if method:
                    logger.debug(f"Request: {method}")
                
                # Rewrite paths: host -> container
                msg = self.rewriter.rewrite_obj(msg, HOST_ROOT, CONTAINER_ROOT)
                
                # Send to server
                self.write_message(self.child.stdin, msg)
                
                # Handle response
                if "id" in msg:
                    # Request expects response
                    resp = self.read_message(self.child.stdout)
                    if resp is None:
                        logger.warning("No response from server")
                        break
                    
                    # Rewrite paths: container -> host
                    resp = self.rewriter.rewrite_obj(resp, CONTAINER_ROOT, HOST_ROOT)
                    self.write_message(sys.stdout.buffer, resp)
                
            except KeyboardInterrupt:
                logger.info("Interrupted by user")
                break
            except Exception as e:
                logger.error(f"Unexpected error: {e}\n{traceback.format_exc()}")
                break
        
        # Cleanup
        if self.child:
            self.child.terminate()
            self.child.wait()
        logger.info("Proxy terminated")

if __name__ == "__main__":
    proxy = JsonRpcProxy()
    proxy.run()
]]

	vim.fn.writefile(vim.split(shim, "\n"), shim_path)
	vim.fn.setfperm(shim_path, "rwxr-xr-x")
	return shim_path
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

	local cmd = vim.list_extend(
		vim.deepcopy(M.state.opts.docker.compose_cmd),
		{ "exec", "-T", service, "python", "-m", "pip", "install", "--user", "pyright" }
	)

	local result = vim.fn.system(cmd)
	if vim.v.shell_error ~= 0 then
		vim.notify("Failed to install Pyright in container:\n" .. result, vim.log.levels.ERROR)
		return false
	end

	M.state.cache.container_pyright = true
	vim.notify("Pyright installed successfully", vim.log.levels.INFO)
	return true
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
	local shim_path = write_shim_file(host, container)

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

	vim.list_extend(cmd, {
		opts.service,
		"python",
		shim_path:gsub(vim.pesc(host), container),
	})

	return cmd
end

local function build_local_cmd(python_bin)
	return { python_bin, "-m", "pyright", "--stdio" }
end

local function stop_pyright()
	for _, client in ipairs(vim.lsp.get_clients({ name = "pyright" })) do
		client.stop(true)
	end
end

local function start_pyright(cmd, settings)
	stop_pyright()

	lspconfig.pyright.setup({
		cmd = cmd,
		root_dir = function(fname)
			return vim.fs.dirname(vim.fs.find(".git", { path = fname, upward = true })[1]) or project_root()
		end,
		settings = settings or {},
		on_init = function(client)
			-- Additional initialization if needed
			vim.notify("Pyright LSP initialized", vim.log.levels.DEBUG)
		end,
		on_attach = function(client, bufnr)
			-- Custom on_attach logic
			if M.state.opts.on_attach then
				M.state.opts.on_attach(client, bufnr)
			end
		end,
	})

	-- Restart for current Python buffers
	vim.defer_fn(function()
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "python" then
				vim.api.nvim_buf_call(buf, function()
					vim.cmd("LspStart pyright")
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
	local clients = vim.lsp.get_clients({ name = "pyright" })
	if #clients == 0 then
		health.status = health.status == "healthy" and "degraded" or health.status
		health.details.lsp = "Pyright LSP not running"
	end

	M.state.health = health
	return health
end

-- Public API ------------------------------------------------------------------
function M.setup(opts)
	M.state.opts = merge_tables(M.defaults, opts or {})

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
		start_pyright(build_docker_cmd(interpreter.opts), M.state.opts.pyright_settings)
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
