return {
  {
    "nvim-treesitter/nvim-treesitter",
    lazy = false,
    build = ":TSInstall bash c css cpp go html java javascript json lua markdown markdown_inline python rust tsx typescript",
    config = function()
      local ts_ft = {
        "bash", "c", "css", "cpp", "go", "html", "java", "javascript",
        "json", "lua", "markdown", "markdown_inline", "python", "rust",
        "tsx", "typescript",
      }

      require("nvim-treesitter").setup({})

      vim.api.nvim_create_autocmd("FileType", {
        pattern = ts_ft,
        callback = function()
          -- parser may not be installed yet; don't hard-error on missing parsers
          if pcall(vim.treesitter.start) then
            vim.bo.indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
          end
        end,
      })
    end,
  },
}