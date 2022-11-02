local buf, job_id
local win = nil
local glow = {}

-- default configs
glow.config = {
  glow_path = vim.fn.exepath("glow"),
  install_path = vim.env.HOME .. "/.local/bin",
  border = "shadow",
  style = vim.o.background,
  mouse = false,
  pager = false,
  use_float = false,
  width = 100,
  height = 100,
}

local function close_window()
  vim.api.nvim_win_close(win, true)
end

local function tmp_file(name)
  -- Get the contents of the current buffer
  local output = vim.api.nvim_buf_get_lines(0, 0, vim.api.nvim_buf_line_count(0), false)
  if vim.tbl_isempty(output) then
    vim.notify("buffer is empty", vim.log.levels.ERROR)
    return
  end

  tmp = vim.fn.tempname() .. ".md"

  -- Copy the contents of the file into the tmp file
  vim.fn.writefile(output, tmp)

  return tmp
end

local function stop_job()
  if job_id == nil then
    return
  end
  vim.fn.jobstop(job_id)
end

local function open_window(cmd, file)
  -- If we don't already have a preview window open, open one
  local src_win = vim.api.nvim_get_current_win()
  wins = vim.api.nvim_list_wins()
  if #wins < 2 then
    vim.cmd('vsplit')
    wins = vim.api.nvim_list_wins()
  end
  win = wins[#wins]
  vim.api.nvim_set_current_win(win)

  -- Create an autocmd group for the auto-update (live preview)
  grp = vim.api.nvim_create_augroup("GlowGrp", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    pattern = "*.md",
    command = ":Glow",
    group = "GlowGrp",
  })

  -- Create a fresh buffer (delete existing if needed)
  if buf ~= nil then
    vim.api.nvim_win_set_buf(win, buf)
    vim.cmd("Kwbd")
  end
  buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_buf_attach(buf, false, {
    on_detach = function()
      buf = nil
    end,
  })

  -- Create a tmp output dir (sorry, Linux only right now)
  os.execute("mkdir -p /tmp/nvim/glow")
  local cbs = {
    on_exit = function()
      vim.api.nvim_set_current_win(win)
      -- Rename the term window to a temp file with a consistent name
      vim.cmd("keepalt file /tmp/nvim/glow/output.mdp")
      -- Why does this not work?
      vim.api.nvim_set_current_win(src_win)
    end,
  }
  job_id = vim.fn.termopen(cmd, cbs)
end


local function open_float_window(cmd, tmp)
  local width = vim.o.columns
  local height = vim.o.lines
  local win_height = math.ceil(height * 0.7)
  local win_width = math.ceil(width * 0.7)
  local row = math.ceil((height - win_height) / 2 - 1)
  local col = math.ceil((width - win_width) / 2)

  if glow.config.width and glow.config.width < win_width then
    win_width = glow.config.width
  end

  if glow.config.height and glow.config.height < win_height then
    win_height = glow.config.height
  end

  local win_opts = {
    style = "minimal",
    relative = "editor",
    width = win_width,
    height = win_height,
    row = row,
    col = col,
    border = glow.config.border,
  }

  -- create preview buffer and set local options
  buf = vim.api.nvim_create_buf(false, true)
  win = vim.api.nvim_open_win(buf, true, win_opts)

  -- options
  vim.api.nvim_win_set_option(win, "winblend", 0)
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "filetype", "glowpreview")

  -- keymaps
  local keymaps_opts = { noremap = true, silent = true, buffer = buf }
  vim.keymap.set("n", "q", close_window, keymaps_opts)
  vim.keymap.set("n", "<Esc>", close_window, keymaps_opts)

  local cbs = {
    on_exit = function()
      if tmp ~= nil then
        vim.fn.delete(tmp)
      end
    end,
  }
  job_id = vim.fn.termopen(cmd, cbs)

  if glow.config.pager then
    vim.cmd("startinsert")
  end
end

local function release_file_url()
  local os, arch
  local version = "1.4.1"

  -- check pre-existence of required programs
  if vim.fn.executable("curl") == 0 or vim.fn.executable("tar") == 0 then
    vim.notify("cURL and/or tar are required!", vim.log.levels.ERROR)
    return
  end

  -- local raw_os = jit.os
  local raw_os = vim.loop.os_uname().sysname
  local raw_arch = jit.arch
  local os_patterns = {
    ["Windows"] = "Windows",
    ["Linux"] = "linux",
    ["Darwin"] = "Darwin",
    ["BSD"] = "freebsd",
  }

  local arch_patterns = {
    ["x86"] = "i386",
    ["x64"] = "x86_64",
    ["arm"] = "arm7",
    ["arm64"] = "arm64",
  }

  os = os_patterns[raw_os]
  arch = arch_patterns[raw_arch]

  if os == nil or arch == nil then
    vim.notify("OS not supported", vim.log.levels.ERROR)
    return ""
  end

  -- win install not supported for now
  if os == "Windows" then
    vim.notify("install script not supported on Windows yet. Please install glow manually", vim.log.levels.WARN)
    return ""
  end

  -- create the url, filename based on os, arch, version
  local filename = "glow_" .. version .. "_" .. os .. "_" .. arch .. ".tar.gz"
  return "https://github.com/charmbracelet/glow/releases/download/v" .. version .. "/" .. filename
end

local function is_md_ft()
  local allowed_fts = { "markdown", "markdown.pandoc", "markdown.gfm", "wiki", "vimwiki", "telekasten" }
  if not vim.tbl_contains(allowed_fts, vim.bo.filetype) then
    return false
  end
  return true
end

local function is_md_ext(ext)
  local allowed_exts = { "md", "markdown", "mkd", "mkdn", "mdwn", "mdown", "mdtxt", "mdtext", "rmd", "wiki" }
  if not vim.tbl_contains(allowed_exts, ext) then
    return false
  end
  return true
end

local function execute(opts)
  local file, tmp

  -- check if glow binary is valid even if filled in config
  if vim.fn.executable(glow.config.glow_path) == 0 then
    vim.notify(
      string.format(
        "could not execute glow binary in path=%s . make sure you have the right config",
        glow.config.glow_path
      ),
      vim.log.levels.ERROR
    )
    return
  end

  local filename = opts.fargs[1]

  if filename ~= nil and filename ~= "" then
    -- check file
    file = opts.fargs[1]
    if not vim.fn.filereadable(file) then
      vim.notify("error on reading file", vim.log.levels.ERROR)
      return
    end

    local ext = vim.fn.fnamemodify(file, ":e")
    if not is_md_ext(ext) then
      vim.notify("preview only works on markdown files", vim.log.levels.ERROR)
      return
    end
  else
    if not is_md_ft() then
      vim.notify("preview only works on markdown files", vim.log.levels.ERROR)
      return
    end

    -- Buffer (file) name
    filename = vim.api.nvim_buf_get_name(0)
  end

  stop_job()

  local cmd_args = { glow.config.glow_path, "-s " .. glow.config.style }

  if glow.config.pager then
    table.insert(cmd_args, "-p")
  end

  table.insert(cmd_args, filename)
  local cmd = table.concat(cmd_args, " ")
  if glow.config.use_float then
    open_float_window(cmd, filename)
  else
    open_window(cmd, filename)
  end
end

local function install_glow(opts)
  local release_url = release_file_url()
  if release_url == "" then
    return
  end

  local install_path = glow.config.install_path
  local download_command = { "curl", "-sL", "-o", "glow.tar.gz", release_url }
  local extract_command = { "tar", "-zxf", "glow.tar.gz", "-C", install_path }
  local output_filename = "glow.tar.gz"
  ---@diagnostic disable-next-line: missing-parameter
  local binary_path = vim.fn.expand(table.concat({ install_path, "glow" }, "/"))

  -- check for existing files / folders
  if vim.fn.isdirectory(install_path) == 0 then
    vim.loop.fs_mkdir(glow.config.install_path, tonumber("777", 8))
  end

  ---@diagnostic disable-next-line: missing-parameter
  if vim.fn.filereadable(binary_path) == 1 then
    local success = vim.loop.fs_unlink(binary_path)
    if not success then
      vim.notify("glow binary could not be removed!", vim.log.levels.ERROR)
      return
    end
  end

  -- download and install the glow binary
  local callbacks = {
    on_sterr = vim.schedule_wrap(function(_, data, _)
      local out = table.concat(data, "\n")
      vim.notify(out, vim.log.levels.ERROR)
    end),
    on_exit = vim.schedule_wrap(function()
      vim.fn.system(extract_command)
      -- remove the archive after completion
      if vim.fn.filereadable(output_filename) == 1 then
        local success = vim.loop.fs_unlink(output_filename)
        if not success then
          return vim.notify("existing archive could not be removed!", vim.log.levels.ERROR)
        end
      end
      glow.config.glow_path = binary_path
      execute(opts)
    end),
  }
  vim.fn.jobstart(download_command, callbacks)
end

local function get_executable()
  if glow.config.glow_path ~= "" then
    return glow.config.glow_path
  end

  return vim.fn.exepath("glow")
end

glow.setup = function(params)
  glow.config = vim.tbl_extend("force", {}, glow.config, params or {})
end

glow.execute = function(opts)
  if vim.version().minor < 7 then
    vim.notify_once("glow.nvim: you must use neovim 0.7 or higher", vim.log.levels.ERROR)
    return
  end

  local current_win = vim.fn.win_getid()
  if current_win == win then
    if opts.bang then
      close_window()
    end
    -- do nothing
    return
  end

  if get_executable() == "" then
    install_glow(opts)
    return
  end

  execute(opts)
end

return glow
