-- dynamic routing based on JWT Claim

local BatchQueue = require "kong.tools.batch_queue"
local cjson = require "cjson"
local url = require "socket.url"
local http = require "resty.http"
local table_clear = require "table.clear"
local sandbox = require "kong.tools.sandbox".sandbox
local kong_meta = require "kong.meta"

local sub = string.sub
local type = type
local pairs = pairs
local lower = string.lower

local jwt_decoder = require "kong.plugins.jwt.jwt_parser"


local JWT2Header = {
  PRIORITY = 900,
  VERSION = "1.0"
}

local kong = kong
local ngx = ngx
local encode_base64 = ngx.encode_base64
local tostring = tostring
local tonumber = tonumber
local concat = table.concat
local fmt = string.format
local pairs = pairs


local sandbox_opts = { env = { kong = kong, ngx = ngx } }


local queues = {} -- one queue per unique plugin config
local parsed_urls_cache = {}
local headers_cache = {}
local params_cache = {
  ssl_verify = false,
  headers = headers_cache,
}


function JWT2Header:rewrite(conf)
   kong.service.request.set_header("X-Kong-JWT-Kong-Proceed", "no")
  kong.log.debug(kong.request.get_header("Authorization") )
   local claims = nil
  local header = nil
   if kong.request.get_header("Authorization") ~= nil then kong.log.debug(kong.request.get_header("Authorization") )
    if  string.match(lower(kong.request.get_header("Authorization")), 'bearer') ~= nil then kong.log.debug("2" ..   kong.request.get_path() )
            local jwt, err = jwt_decoder:new((sub(kong.request.get_header("Authorization"), 8)))
                if err then
              return false, { status = 401, message = "Bad token; " .. tostring(err) }
            end

            claims = jwt.claims
            header = jwt.header
           kong.service.request.set_header("X-Kong-JWT-Kong-Proceed", "yes")
    end
  end
  


  if kong.request.get_header("X-Kong-JWT-Kong-Proceed") == "yes" then
    for claim, value in pairs(claims) do
      if type(claim) == "string" and type(value) == "string" then
        kong.service.request.set_header("X-Kong-JWT-Claim-" .. claim, value)
      end
    end
   end
 
end


function JWT2Header:access(conf)
  if kong.request.get_header("X-Kong-JWT-Kong-Proceed") == "yes" then    
      -- ctx oesn't work in kong 1.5, only in 2.x local claims = kong.ctx.plugin.claims
      local claims = kong.request.get_headers();
      if not claims then
        kong.log.debug("empty claim" )
        return
      end

    if conf.strip_claims == "true" then
      for claim, value in pairs(claims) do
          kong.log.debug("found header " .. claim )
        if type(claim) == "string" and string.match(claim, 'x%-kong%-jwt%-claim') ~= nil then  
          kong.service.request.clear_header(claim)
          kong.log.debug("removed header " .. claim)
        end
      end
      kong.service.request.clear_header("X-Kong-JWT-Kong-Proceed")
    end

      --kong.ctx.plugin.claims = nil
   elseif conf.token_required == "true" then 
        kong.service.request.clear_header("X-Kong-JWT-Kong-Proceed")
        kong.response.exit(404, '{"error": "No valid JWT token found"}')
   else kong.service.request.clear_header("X-Kong-JWT-Kong-Proceed")
   
  end
end


-- Parse host url.
-- @param `url` host url
-- @return `parsed_url` a table with host details:
-- scheme, host, port, path, query, userinfo
local function parse_url(host_url)
  local parsed_url = parsed_urls_cache[host_url]

  if parsed_url then
    return parsed_url
  end

  parsed_url = url.parse(host_url)
  if not parsed_url.port then
    if parsed_url.scheme == "http" then
      parsed_url.port = 80
    elseif parsed_url.scheme == "https" then
      parsed_url.port = 443
    end
  end
  if not parsed_url.path then
    parsed_url.path = "/"
  end

  parsed_urls_cache[host_url] = parsed_url

  return parsed_url
end

-- Sends the provided payload (a string) to the configured plugin host
-- @return true if everything was sent correctly, falsy if error
-- @return error message if there was an error
local function send_payload(self, conf, payload)
  local method = conf.method
  local timeout = conf.timeout
  local keepalive = conf.keepalive
  local content_type = conf.content_type
  local http_endpoint = conf.http_endpoint

  local parsed_url = parse_url(http_endpoint)
  local host = parsed_url.host
  local port = tonumber(parsed_url.port)

  local httpc = http.new()
  httpc:set_timeout(timeout)

  table_clear(headers_cache)
  if conf.headers then
    for h, v in pairs(conf.headers) do
      headers_cache[h] = v
    end
  end

  headers_cache["Host"] = parsed_url.host
  headers_cache["Content-Type"] = content_type
  headers_cache["Content-Length"] = #payload
  if parsed_url.userinfo then
    headers_cache["Authorization"] = "Basic " .. encode_base64(parsed_url.userinfo)
  end

  params_cache.method = method
  params_cache.body = payload
  params_cache.keepalive_timeout = keepalive

  local url = fmt("%s://%s:%d%s", parsed_url.scheme, parsed_url.host, parsed_url.port, parsed_url.path)

  -- note: `httpc:request` makes a deep copy of `params_cache`, so it will be
  -- fine to reuse the table here
  local res, err = httpc:request_uri(url, params_cache)
  if not res then
    return nil, "failed request to " .. host .. ":" .. tostring(port) .. ": " .. err
  end

  -- always read response body, even if we discard it without using it on success
  local response_body = res.body
  local success = res.status < 400
  local err_msg

  if not success then
    err_msg = "request to " .. host .. ":" .. tostring(port) ..
              " returned status code " .. tostring(res.status) .. " and body " ..
              response_body
  end

  return success, err_msg
end


local function json_array_concat(entries)
  return "[" .. concat(entries, ",") .. "]"
end


local function get_queue_id(conf)
  return fmt("%s:%s:%s:%s:%s:%s",
             conf.http_endpoint,
             conf.method,
             conf.content_type,
             conf.timeout,
             conf.keepalive,
             conf.retry_count,
             conf.queue_size,
             conf.flush_timeout)
end


return JWT2Header
