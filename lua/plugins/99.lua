return {
  {
    "ThePrimeagen/99",
    keys = {
      { "<leader>9s", function() require("99").search() end, desc = "99 search" },
      { "<leader>9v", function() require("99").visual() end, mode = "v", desc = "99 visual" },
      { "<leader>9x", function() require("99").stop_all_requests() end, desc = "99 stop" },
      { "<leader>9o", function() require("99").open() end, desc = "99 previous" },
      { "<leader>9m", function() require("99.extensions.fzf_lua").select_model() end, desc = "99 model" },
      { "<leader>9p", function() require("99.extensions.fzf_lua").select_provider() end, desc = "99 provider" },
    },
    config = function()
      require("99").setup({
        provider = require("99").Providers.OpenCodeProvider, -- default
        model = "opencode/deepseek-v4-flash-free",
        completion = { source = "native" },
        md_files = { "AGENT.md" },
      })
    end,
  },
}