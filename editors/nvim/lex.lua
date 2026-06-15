-- Cliente LSP do lex para Neovim (0.8+), sem plugins.
--
-- Sobe o `lex lsp` (o Language Server embutido no compilador, veja src/lsp.rs)
-- por stdio e mostra os diagnósticos ao vivo. Uso:
--
--   require("lex").setup()                       -- acha o binário no projeto
--   require("lex").setup({ cmd = "/caminho/lex" })  -- binário explícito
--
-- Coloque este arquivo no runtimepath (ex.: ~/.config/nvim/lua/lex.lua) e
-- chame o setup() no seu init.lua.

local M = {}

-- Sobe da pasta do arquivo procurando target/release/lex e depois
-- target/debug/lex. NÃO cai pro `lex` do PATH: em Unix /usr/bin/lex é o flex.
local function find_binary(start)
  local dir = vim.fn.fnamemodify(start, ":p:h")
  while dir and dir ~= "" do
    for _, rel in ipairs({ "target/release/lex", "target/debug/lex" }) do
      local cand = dir .. "/" .. rel
      if vim.fn.executable(cand) == 1 then
        return cand
      end
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      break
    end
    dir = parent
  end
  return nil
end

-- Procura a raiz do projeto (Cargo.toml ou .git) para fixar o root_dir do LSP.
local function find_root(start)
  local markers = { "Cargo.toml", ".git", "lex.lock" }
  local found = vim.fs.find(markers, { upward = true, path = start })[1]
  if found then
    return vim.fs.dirname(found)
  end
  return vim.fn.fnamemodify(start, ":p:h")
end

function M.setup(opts)
  opts = opts or {}

  -- *.lex => filetype "lex"
  vim.filetype.add({ extension = { lex = "lex" } })

  vim.api.nvim_create_autocmd("FileType", {
    pattern = "lex",
    callback = function(args)
      local file = vim.api.nvim_buf_get_name(args.buf)
      local bin = opts.cmd or find_binary(file)
      if not bin then
        vim.notify(
          "lex: binário não encontrado. Rode `cargo build --release` ou "
            .. "passe { cmd = '/caminho/lex' } para require('lex').setup().",
          vim.log.levels.WARN
        )
        return
      end

      vim.lsp.start({
        name = "lex-lsp",
        cmd = { bin, "lsp" },
        root_dir = find_root(file),
      }, { bufnr = args.buf })
    end,
  })
end

return M
