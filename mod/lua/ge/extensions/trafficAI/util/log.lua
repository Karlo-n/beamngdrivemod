local M = {}

local tag = 'trafficAI'

M.verbose = false

function M.i(msg)
  if M.verbose then log('I', tag, msg) end
end

function M.w(msg)
  log('W', tag, msg)
end

function M.e(msg)
  log('E', tag, msg)
end

return M
