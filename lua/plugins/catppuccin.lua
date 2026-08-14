return {
  {
    "catppuccin/nvim",
    name = "catppuccin",
    lazy = false,
    priority = 1000,
    config = function()
      require("catppuccin").setup({
        flavour = "frappe",
        transparent_background = true,
        styles = {
          sidebars = "transparent",
          floats = "transparent",
        },
      })
    end,
  },
}
