return {
  {
    "catgoose/nvim-colorizer.lua",
    event = "VeryLazy",
    config = function()
      require("colorizer").setup({
        filetypes = { "*" },
        options = {
          parsers = {
            css = true, -- hex, rgb(), hsl(), oklch(), css variables
            names = { enable = false }, -- "Name" codes like Blue
          },
        },
      })
    end,
  },
}
