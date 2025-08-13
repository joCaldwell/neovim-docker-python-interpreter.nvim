# THIS PROJECT IS A WIP AND IS NOT CURRENTLY FUNCTIONAL

# 🐳 neovim-docker-python-interpreter.nvim

A Neovim plugin that seamlessly integrates Pyright LSP with Docker containers, solving the path mismatch problem between host and container environments. Perfect for Python development in containerized environments.

![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-green.svg)
![Python](https://img.shields.io/badge/Python-3.7%2B-blue.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

## ✨ Features

- **🔄 Seamless Path Translation**: Automatically translates file paths between host and container environments
- **🎯 Smart Interpreter Selection**: Choose between local virtual environments or Docker containers
- **🚀 Auto-discovery**: Automatically finds Poetry, Pipenv, venv, and other virtual environments
- **💾 Intelligent Caching**: Caches discovery results for better performance
- **🏥 Health Monitoring**: Built-in health check system with periodic monitoring
- **🔧 Auto-configuration**: Can automatically select the best interpreter based on your setup
- **📦 Zero Container Setup**: Automatically installs Pyright in containers when needed
- **🐛 Debug Support**: Comprehensive logging for troubleshooting

## 📋 Requirements

- Neovim >= 0.10
- [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig)
- Python 3.7+ (on host and in container)
- Docker and Docker Compose (for container support)
- Optional: [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) for enhanced path handling

## 📦 Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "yourusername/neovim-docker-python-interpreter.nvim",
  dependencies = {
    "neovim/nvim-lspconfig",
    "nvim-lua/plenary.nvim", -- optional but recommended
  },
  config = function()
    require("docker_python_interpreter").setup({
      -- your configuration here
    })
  end,
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "yourusername/neovim-docker-python-interpreter.nvim",
  requires = {
    "neovim/nvim-lspconfig",
    "nvim-lua/plenary.nvim", -- optional
  },
  config = function()
    require("docker_python_interpreter").setup({
      -- your configuration here
    })
  end,
}
```

## ⚙️ Configuration

### Basic Setup

```lua
require("docker_python_interpreter").setup({
  -- Docker configuration
  docker = {
    service = "web",                    -- Your docker-compose service name
    workdir = "/srv/app",               -- Working directory inside container
    compose_cmd = {"docker", "compose"}, -- Command to run docker compose
    auto_install_pyright = true,        -- Auto-install Pyright in container
    health_check_interval = 300,        -- Health check interval in seconds (0 to disable)
    path_map = {
      container_root = "/srv/app",      -- Root path in container
      host_root = nil,                  -- Root path on host (nil = auto-detect)
    },
  },
  
  -- Pyright LSP settings
  pyright_settings = {
    python = {
      analysis = {
        autoSearchPaths = true,
        diagnosticMode = "workspace",
        typeCheckingMode = "basic",
      },
    },
  },
  
  -- Plugin behavior
  auto_select = false,     -- Auto-select interpreter if only one available
  prefer_docker = false,   -- Prefer Docker over local when both available
  cache_ttl = 60,         -- Cache discovery results for N seconds
  
  -- Optional: Custom on_attach function for LSP
  on_attach = function(client, bufnr)
    -- Your custom LSP keybindings/settings
  end,
})
```

### Advanced Configuration Examples

#### For Django Projects

```lua
require("docker_python_interpreter").setup({
  docker = {
    service = "django",
    workdir = "/code",
    path_map = {
      container_root = "/code",
      host_root = vim.fn.getcwd(),
    },
  },
  pyright_settings = {
    python = {
      analysis = {
        extraPaths = { "/code/apps" },
        autoSearchPaths = true,
        useLibraryCodeForTypes = true,
      },
    },
  },
  auto_select = true,
  prefer_docker = true,
})
```

#### For FastAPI Projects with Poetry

```lua
require("docker_python_interpreter").setup({
  docker = {
    service = "api",
    workdir = "/app",
    compose_cmd = {"docker-compose"},  -- If using older docker-compose
  },
  auto_select = true,
  prefer_docker = false,  -- Prefer local Poetry environment
})
```

## 🎮 Usage

### Commands

| Command | Description |
|---------|-------------|
| `:SelectPythonInterpreter` | Open interpreter selection menu |
| `:PythonInterpreterInfo` | Show current interpreter information and health status |
| `:PythonInterpreterHealth` | Check and display health status |
| `:RestartPyright` | Restart Pyright with current interpreter |

### Typical Workflow

1. **Open your Python project** in Neovim
2. **Run `:SelectPythonInterpreter`** to choose your interpreter
3. **Select from options:**
   - Docker container (if available and running)
   - Local virtual environments (auto-discovered)
   - System Python
   - Manual path entry
4. **Start coding!** Pyright will now work correctly with your chosen environment

### Interpreter Selection Priority

When `auto_select` is enabled, the plugin uses this priority:

1. If `prefer_docker` is true and Docker is available → Use Docker
2. If only one local venv exists and Docker is unavailable → Use that venv
3. If no local venv exists but Docker is available → Use Docker
4. Otherwise → Manual selection required

## 🔧 How It Works

### The Path Translation Problem

When using Pyright in a Docker container, file paths don't match:
- **Host**: `/home/user/myproject/main.py`
- **Container**: `/srv/app/main.py`

This breaks LSP features like go-to-definition, diagnostics, and auto-imports.

### The Solution: JSON-RPC Proxy

The plugin creates a Python shim that acts as a transparent proxy between Neovim and Pyright:

```
Neovim ←→ [Path Translation Shim] ←→ Pyright (in Docker)
```

The shim:
1. Intercepts all JSON-RPC messages
2. Rewrites file paths in both directions
3. Maintains full LSP protocol compatibility
4. Handles all edge cases (URIs, workspace folders, etc.)

## 🐛 Troubleshooting

### Enable Debug Logging

```bash
# Set environment variable before starting Neovim
export DEBUG_DOCKER_PYTHON=1
nvim
```

Check the shim log:
```bash
tail -f /tmp/pyright_shim.log
```

### Common Issues

#### "Container not running"
**Solution**: Start your Docker container first:
```bash
docker compose up -d
```

#### "Pyright not found in container"
**Solution**: Either:
- Enable `auto_install_pyright = true` in config
- Manually install in container: `docker compose exec web pip install pyright`

#### "No virtual environment found"
**Solution**: Create a virtual environment:
```bash
python -m venv .venv
# or
poetry install
# or
pipenv install
```

#### Path translation not working
**Solution**: Check your path mapping configuration:
```lua
docker = {
  path_map = {
    container_root = "/actual/container/path",  -- Must match your Docker mount
    host_root = vim.fn.getcwd(),                -- Must be your project root
  },
}
```

### Health Check Details

Run `:PythonInterpreterHealth` to see detailed status:

```
Health: healthy
{
  details = {},
  status = "healthy",
  timestamp = 1234567890
}
```

Possible statuses:
- `healthy`: Everything working
- `degraded`: Working with minor issues
- `unhealthy`: Critical problems
- `unconfigured`: No interpreter selected

## 🏗️ Project Structure

```
.
├── lua/
│   └── docker_python_interpreter.lua  # Main plugin code
├── .nvim/
│   └── docker_pyright_shim.py        # Auto-generated path translation shim
├── README.md
└── LICENSE
```

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

### Development Setup

1. Fork the repository
2. Clone your fork
3. Create a feature branch
4. Make your changes
5. Add tests if applicable
6. Submit a PR

### Running Tests

```bash
# If tests are available
make test
```

## 📝 License

MIT License - see [LICENSE](LICENSE) file for details

## 🙏 Acknowledgments

- Original concept inspired by the need for better Docker integration in Neovim
- Thanks to the Neovim and nvim-lspconfig maintainers
- The Python LSP community for Pyright

## 🚀 Roadmap

- [ ] Support for multiple containers simultaneously
- [ ] Integration with devcontainers
- [ ] Support for other Python LSP servers (pylsp, jedi-language-server)
- [ ] Automatic interpreter switching based on project
- [ ] GUI picker using Telescope
- [ ] Support for remote Docker hosts
- [ ] Integration with DAP (Debug Adapter Protocol)

## 💬 Support

- **Issues**: [GitHub Issues](https://github.com/yourusername/neovim-docker-python-interpreter.nvim/issues)
- **Discussions**: [GitHub Discussions](https://github.com/yourusername/neovim-docker-python-interpreter.nvim/discussions)

## ⭐ Star History

If you find this plugin useful, please consider giving it a star on GitHub!

---

<p align="center">Made with ❤️ for the Neovim community</p>
