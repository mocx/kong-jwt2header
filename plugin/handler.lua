-- dynamic routing based on JWT Claim

local BatchQueue = require "kong.tools.batch_queue"
local cjson = require "cjson"
local url = require "socket.url"
local http = require "resty.http"
local table_clear = require "table.clear"
local sandbox = require "kong.tools.sandbox".sandbox
local zlib = require "ffi-zlib"


local sub = string.sub
local type = type
local pairs = pairs
local lower = string.lower
local inflate_gzip  = zlib.inflateGzip

local jwt_decoder = require "kong.plugins.jwt.jwt_parser"


local HttpLogHandler = {
  PRIORITY = 12,
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

-- check for nil or emptu.
-- @param `string` host url
-- @return `true or false`
local function isempty(s)
  return s == nil or s == ''
end

-- Sends the provided payload (a string) to the configured plugin host
-- @return true if everything was sent correctly, falsy if error
-- @return error message if there was an error
local function log_payload(self, conf, payload)
  ngx.log(ngx.NOTICE, "http log" .. payload)
  local success = true
  local err_msg
  local http_endpoint = conf.http_endpoint
  if not isempty(http_endpoint) then
    local method = conf.method
    local timeout = conf.timeout
    local keepalive = conf.keepalive
    local content_type = conf.content_type
    

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
    success = res.status < 400

    if not success then
      err_msg = "request to " .. host .. ":" .. tostring(port) ..
                " returned status code " .. tostring(res.status) .. " and body " ..
                response_body
    end

    
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

function HttpLogHandler:access(conf)
  --do this to get the response body else "Error: service body is only available with buffered proxying"
  kong.service.request.enable_buffering()
end


function HttpLogHandler:log(conf)
  --ngx.log(ngx.NOTICE, "HttpLogHandler:log")
  --ngx.log(ngx.NOTICE, "HttpLogHandler:log: incoming body" .. ngx.req.get_body_data())
  local logit = false
  local graph_call =  tostring(ngx.var.upstream_uri) == conf.graphql_uri

  if not graph_call and not tostring(kong.response.get_status()):find("2", 1, true) == 1 then
    logit = true
  end
  if graph_call then
    ngx.log(ngx.NOTICE, kong.service.response.get_raw_body())
    local body_ = cjson.decode(kong.service.response.get_raw_body())
    ngx.log(ngx.NOTICE, body_["errors"])
    logit = not body_["errors"]  == nil
  end
  if logit then
    if conf.custom_fields_by_lua then
      local set_serialize_value = kong.log.set_serialize_value
      for key, expression in pairs(conf.custom_fields_by_lua) do
        set_serialize_value(key, sandbox(expression, sandbox_opts)())
      end
    end

    local responseBod = kong.service.response.get_raw_body()
    local encoding = kong.response.get_header("Content-Encoding")
    if encoding == "gzip" then
      responseBod = inflate_gzip(responseBod)
    end

    local jsonObj = kong.log.serialize()
    jsonObj.response.body = responseBod
    -- remove all data we done need from the log payload
    jsonObj.route = nil
    jsonObj.tries = nil
    jsonObj.service = nil
    jsonObj.workspace = nil
    jsonObj.authenticated_entity = nil
    jsonObj.request.uri = nil
    jsonObj.request.size = nil
    jsonObj.request.querystring = nil
    jsonObj.response.size = nil
    jsonObj.response.headers = nil
    jsonObj.started_at = nil
    jsonObj.client_ip = nil
    -- remove all other headers except those that start with 'x-'
    for k, v in pairs(jsonObj.request.headers) do
      --print(k," ", v)
      if not (k:find("x", 1, true) == 1 or k:find("X", 1, true) == 1) then 
        print(k," ", v)
        jsonObj.request.headers[k] = nil
      end
      --ngx.log(ngx.NOTICE, "http log" .. payload)
    end
    local entry = cjson.encode(jsonObj)
  
    local queue_id = get_queue_id(conf)
    local q = queues[queue_id]
    if not q then
      -- batch_max_size <==> conf.queue_size
      local batch_max_size = conf.queue_size or 1
      local process = function(entries)
        local payload = batch_max_size == 1
                        and entries[1]
                        or  json_array_concat(entries)
        return log_payload(self, conf, payload)
      end
  
      local opts = {
        retry_count    = conf.retry_count,
        flush_timeout  = conf.flush_timeout,
        batch_max_size = batch_max_size,
        process_delay  = 0,
      }
  
      local err
      q, err = BatchQueue.new(process, opts)
      if not q then
        kong.log.err("could not create queue: ", err)
        return
      end
      queues[queue_id] = q
    end
  
    q:add(entry)
  end
  
end


return HttpLogHandler
