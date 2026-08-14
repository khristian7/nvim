return {
  {
    "numToStr/FTerm.nvim",
    lazy = true,
    config = function()
      local fterm = require("FTerm")

      _G.htop = fterm:new({
        ft = 'fterm_htop',
        cmd = "htop"
      })
    end,
  },
}