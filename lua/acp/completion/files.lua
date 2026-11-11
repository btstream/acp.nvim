-- Shared, bounded project indexes. Discovery is asynchronous and never depends
-- on the current query: a deep match cannot be lost to an early candidate cap.
local M = {}
local cache = {}
local serial = 0

local function now()
  return vim.uv.hrtime() / 1e6
end

function M.relative(path, base)
  path, base = vim.fs.normalize(path, { expand_env = false }), vim.fs.normalize(base, { expand_env = false })
  local a, b = vim.split(path, "/", { plain = true }), vim.split(base, "/", { plain = true })
  if a[1] ~= b[1] then
    return path
  end
  local i = 1
  while a[i] and a[i] == b[i] do
    i = i + 1
  end
  local out = {}
  for _ = i, #b do
    out[#out + 1] = ".."
  end
  for j = i, #a do
    out[#out + 1] = a[j]
  end
  return table.concat(out, "/")
end

function M.root(cwd, opts)
  local root = opts.root
  if type(root) == "function" then
    root = root(cwd)
  end
  if not root or root == "" then
    root = vim.fs.root(cwd, { ".git" }) or cwd
  end
  if type(root) ~= "string" or root:find("\0", 1, true) then
    error("completion root must be a path without NUL")
  end
  if not vim.startswith(root, "/") and not root:match("^%a:[/\\]") then
    root = cwd .. "/" .. root
  end
  return vim.fs.normalize(root, { expand_env = false })
end

local function command(root, opts)
  if opts.command then
    return vim.deepcopy(opts.command)
  end
  local backend = opts.backend
  local function has(name)
    return vim.fn.executable(name) == 1
  end
  if backend == "auto" then
    backend = has("rg") and "rg"
      or (has("fd") or has("fdfind")) and "fd"
      or (has("git") and vim.fs.root(root, { ".git" })) and "git"
      or "builtin"
  end
  if backend == "rg" then
    local cmd = { "rg", "--files", "--null", "--glob", "!.git/**" }
    if opts.hidden then
      cmd[#cmd + 1] = "--hidden"
    end
    if opts.ignored then
      cmd[#cmd + 1] = "--no-ignore"
    end
    return cmd
  elseif backend == "fd" then
    local cmd = { has("fd") and "fd" or "fdfind", "--type", "f", "--print0", "--color", "never", "--exclude", ".git" }
    if opts.hidden then
      cmd[#cmd + 1] = "--hidden"
    end
    if opts.ignored then
      cmd[#cmd + 1] = "--no-ignore"
    end
    return cmd
  elseif backend == "git" then
    local cmd = { "git", "ls-files", "--cached", "--others", "-z" }
    if not opts.ignored then
      cmd[#cmd + 1] = "--exclude-standard"
    end
    return cmd
  end
end

local function stop(entry)
  entry.cancelled = true
  local proc = entry.proc
  entry.proc = nil
  if proc then
    pcall(proc.kill, proc, 15)
  end
end

function M.refresh()
  local old = cache
  cache = {}
  for _, entry in pairs(old) do
    stop(entry)
    for _, waiter in pairs(entry.waiters or {}) do
      local ok, problem = pcall(waiter, nil, "file index refreshed")
      if not ok then
        require("acp.log").error("completion refresh callback failed: %s", tostring(problem))
      end
    end
  end
end

function M.list(cwd, opts, callback)
  local ok, root = pcall(M.root, cwd, opts)
  if not ok then
    callback(nil, tostring(root))
    return function() end
  end
  local key = root
    .. "\0"
    .. vim.json.encode({ opts.backend, opts.command or {}, opts.hidden, opts.ignored, opts.max_bytes })
  local entry = cache[key]
  if entry and entry.paths and now() - entry.at <= opts.cache_ms then
    entry.used = now()
    local cancelled = false
    vim.schedule(function()
      if not cancelled then
        callback(entry.paths, nil, root)
      end
    end)
    return function()
      cancelled = true
    end
  end
  if entry and entry.paths then
    cache[key] = nil
    entry = nil
  end
  if not entry then
    local keys = vim.tbl_keys(cache)
    if #keys >= opts.max_projects then
      table.sort(keys, function(a, b)
        return cache[a].used < cache[b].used
      end)
      for _, old in ipairs(keys) do
        if cache[old].paths or next(cache[old].waiters) == nil then
          stop(cache[old])
          cache[old] = nil
          break
        end
      end
      if vim.tbl_count(cache) >= opts.max_projects then
        callback(nil, "too many active completion file indexes")
        return function() end
      end
    end
    entry = { waiters = {}, used = now(), root = root }
    cache[key] = entry
  end
  serial = serial + 1
  local id = serial
  entry.idle_stop = nil
  entry.waiters[id] = callback
  local function cancel()
    entry.waiters[id] = nil
    if not entry.paths and not entry.cancelled and next(entry.waiters) == nil then
      -- Frameworks cancel the previous query before subscribing the next one.
      -- Keep the project scan alive across that handoff, not one process/key.
      local request = {}
      entry.idle_stop = request
      vim.defer_fn(function()
        if entry.idle_stop ~= request or entry.paths or entry.cancelled or next(entry.waiters) ~= nil then
          return
        end
        stop(entry)
        if cache[key] == entry then
          cache[key] = nil
        end
      end, 50)
    end
  end
  if entry.started then
    return cancel
  end
  entry.started = true
  local paths, seen, bytes = {}, {}, 0
  local function finish(err)
    if entry.cancelled then
      return
    end
    entry.cancelled = true
    local waiters = entry.waiters
    entry.waiters = {}
    local proc = entry.proc
    entry.proc = nil
    if err then
      if proc then
        pcall(proc.kill, proc, 15)
      end
      if cache[key] == entry then
        cache[key] = nil
      end
    else
      entry.paths, entry.at = paths, now()
    end
    for _, fn in pairs(waiters) do
      local ok, problem
      if err then
        ok, problem = pcall(fn, nil, err, root)
      else
        ok, problem = pcall(fn, paths, nil, root)
      end
      if not ok then
        require("acp.log").error("completion file callback failed: %s", tostring(problem))
      end
    end
  end
  local function add(path)
    path = path:gsub("^%./", "")
    if path:sub(1, 1) == "/" then
      path = M.relative(path, root)
    end
    if
      path == ".."
      or path:sub(1, 3) == "../"
      or path:match("^%.git/")
      or path == ".git"
      or path:find("/.git/", 1, true)
      or path:sub(-5) == "/.git"
    then
      return
    end
    if not opts.hidden and (path:sub(1, 1) == "." or path:find("/%.", 1)) then
      return
    end
    if path == "" or seen[path] then
      return
    end
    bytes = bytes + #path + 64
    if bytes > opts.max_bytes then
      finish("project file index exceeds completion.files.max_bytes; increase the limit or narrow the root")
      return
    end
    paths[#paths + 1], seen[path] = path, true
  end
  local cmd = command(root, opts)
  if cmd then
    local tail, stderr, received = "", "", 0
    local chunks, head, last, offset = {}, 1, 0, 1
    local scheduled, result, overflowed = false, nil, false
    local pump
    local function kick()
      if scheduled or entry.cancelled then
        return
      end
      scheduled = true
      vim.schedule(pump)
    end
    pump = function()
      scheduled = false
      if entry.cancelled then
        return
      end
      local records = 0
      while head <= last and records < 256 do
        local data = chunks[head]
        local nul = data:find("\0", offset, true)
        if nul then
          add(tail .. data:sub(offset, nul - 1))
          tail, offset, records = "", nul + 1, records + 1
          if entry.cancelled then
            return
          end
        else
          tail = tail .. data:sub(offset)
          chunks[head], head, offset = nil, head + 1, 1
          if #tail > opts.max_bytes then
            finish("completion file name exceeds index budget")
            return
          end
        end
      end
      if head <= last then
        kick()
        return
      end
      chunks, head, last = {}, 1, 0
      if result then
        if result.code ~= 0 and not (cmd[1] == "rg" and result.code == 1) then
          finish("file discovery failed: " .. (stderr ~= "" and stderr or "exit " .. result.code):sub(1, 300))
        elseif tail ~= "" then
          finish("file discovery must emit NUL-delimited paths")
        else
          finish()
        end
      end
    end
    local spawned, proc = pcall(vim.system, cmd, {
      cwd = root,
      stderr = function(_, data)
        if data then
          stderr = (stderr .. data):sub(-4096)
        end
      end,
      stdout = function(err, data)
        if entry.cancelled or overflowed then
          return
        end
        if data then
          received = received + #data
        end
        if received > opts.max_bytes then
          overflowed = true
          vim.schedule(function()
            finish("file discovery output exceeds completion.files.max_bytes")
          end)
          return
        end
        vim.schedule(function()
          if entry.cancelled then
            return
          end
          if err then
            finish(tostring(err))
            return
          end
          if not data then
            return
          end
          last = last + 1
          chunks[last] = data
          kick()
        end)
      end,
    }, function(exit)
      vim.schedule(function()
        if entry.cancelled then
          return
        end
        result = exit
        kick()
      end)
    end)
    if spawned then
      entry.proc = proc
    else
      finish(tostring(proc))
    end
  else
    -- Dependency-free asynchronous fallback. It excludes .git/hidden paths but
    -- does not interpret ignore files; rg/fd/git should be preferred for that.
    local dirs, head = { "" }, 1
    local function collect(path, kind)
      if kind == "directory" then
        bytes = bytes + #path + 64
        if bytes > opts.max_bytes then
          finish("directory index exceeds completion.files.max_bytes")
          return
        end
        dirs[#dirs + 1] = path
      elseif kind == "file" then
        add(path)
      end
    end
    local inspect
    inspect = function(path, kind, done)
      local stat = kind == "link" and vim.uv.fs_stat or vim.uv.fs_lstat
      stat(root .. "/" .. path, function(err, value)
        vim.schedule(function()
          if entry.cancelled then
            return
          end
          if err then
            if not tostring(err):match("^ENOENT") and not tostring(err):match("^ELOOP") then
              finish(tostring(err))
              return
            end
          elseif value.type == "link" then
            inspect(path, "link", done)
            return
          elseif value.type ~= "directory" or kind ~= "link" then
            collect(path, value.type)
          end
          if not entry.cancelled then
            done()
          end
        end)
      end)
    end
    local walk
    walk = function()
      if entry.cancelled then
        return
      end
      local dir = dirs[head]
      if dir == nil then
        finish()
        return
      end
      head = head + 1
      vim.uv.fs_scandir(root .. "/" .. dir, function(err, scan)
        vim.schedule(function()
          if entry.cancelled then
            return
          end
          if err then
            finish(tostring(err))
            return
          end
          local function consume()
            if entry.cancelled then
              return
            end
            for _ = 1, 256 do
              local name, kind = vim.uv.fs_scandir_next(scan)
              if not name then
                vim.schedule(walk)
                return
              end
              if name ~= ".git" and (opts.hidden or name:sub(1, 1) ~= ".") then
                local path = dir == "" and name or dir .. "/" .. name
                if not kind or kind == "unknown" or kind == "link" then
                  inspect(path, kind, consume)
                  return
                end
                collect(path, kind)
                if entry.cancelled then
                  return
                end
              end
            end
            vim.schedule(consume)
          end
          consume()
        end)
      end)
    end
    walk()
  end
  return cancel
end

return M
