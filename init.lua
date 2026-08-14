-- bread's neovim config
-- keymaps are in lua/config/mappings.lua
-- install a patched font & ensure your terminal supports glyphs
-- enjoy :D

-- auto install lazy.nvim, if not found
local lazypath = vim.fn.stdpath('data') .. '/lazy/lazy.nvim'
if not (vim.uv or vim.loop).fs_stat(lazypath) then
	vim.fn.system({
		'git',
		'clone',
		'--filter=blob:none',
		'https://github.com/folke/lazy.nvim.git',
		'--branch=stable',
		lazypath,
	})
end
vim.opt.rtp:prepend(lazypath)

local vim = vim

vim.g.start_time = vim.fn.reltime()
vim.loader.enable() --  SPEEEEEEEEEEED 

-- move config and plugin config to alternate files
require("config.theme")
require("config.mappings")
require("config.options")
require("config.autocmd")

-- plugin specs live in lua/plugins/*.lua, each returns a spec table
require("lazy").setup("plugins", {
	install = {
		colorscheme = { "catppuccin" },
	},
	change_detection = { notify = false },
})

load_theme()
