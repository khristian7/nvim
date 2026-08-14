return {
  {
    "mfussenegger/nvim-lint",
    lazy = false,
    config = function()
      require('lint').linters_by_ft = { --some of these need to be installed from package manager
        lua = { 'luac' },
        python = { 'ruff' },
        sh = { 'bash' },
        c = { 'cppcheck' },
        rust = { 'clippy' },
        css = { 'stylelint' },
        html = { 'htmlhint' },
      }
    end,
  },
}