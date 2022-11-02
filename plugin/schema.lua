local typedefs = require "kong.db.schema.typedefs"
local url = require "socket.url"


return {
  name = "kong-to-loki",
  fields = {
    {
      route = typedefs.no_route,
    },
    {
      service = typedefs.no_service,
    },
    {
      consumer = typedefs.no_consumer,
    },
    {
      protocols = typedefs.protocols,
    },
    {
      config = {
        type = "record",
        fields = {
            {  content_type = { type = "string", default = "application/json", one_of = { "application/json" }, }, },
            {  method = { type = "string", default = "POST", one_of = { "POST", "PUT", "PATCH" }, }, },
            {  timeout = { type = "number", default = 10000 }, },
            {  keepalive = { type = "number", default = 60000 }, },
            {  retry_count = { type = "integer", default = 10 }, },
            {  queue_size = { type = "integer", default = 1 }, },
            {  flush_timeout = { type = "number", default = 2 }, },
            {  strip_claims = { type     = "string", required = true, default  = "false" }, },
            {  token_required = { type     = "string", required = true, default  = "true" }, },
            {  http_endpoint = typedefs.url({ required = true, encrypted = true }) }, -- encrypted = true is a Kong-Enterprise exclusive feature, does nothing in Kong CE
            {  headers = {
                type = "map",
                keys = typedefs.header_name {
                  match_none = {
                    {
                      pattern = "^[Hh][Oo][Ss][Tt]$",
                      err = "cannot contain 'Host' header",
                    },
                    {
                      pattern = "^[Cc][Oo][Nn][Tt][Ee][Nn][Tt]%-[Ll][Ee][nn][Gg][Tt][Hh]$",
                      err = "cannot contain 'Content-Length' header",
                    },
                    {
                      pattern = "^[Cc][Oo][Nn][Tt][Ee][Nn][Tt]%-[Tt][Yy][Pp][Ee]$",
                      err = "cannot contain 'Content-Type' header",
                    },
                  },
                },
                values = {
                  type = "string",
                },
            }},
            { custom_fields_by_lua = typedefs.lua_code },          
        },
        custom_validator = function(config)
          -- check no double userinfo + authorization header
          local parsed_url = url.parse(config.http_endpoint)
          if parsed_url.userinfo and config.headers and config.headers ~= ngx.null then
            for hname, hvalue in pairs(config.headers) do
              if hname:lower() == "authorization" then
                return false, "specifying both an 'Authorization' header and user info in 'http_endpoint' is not allowed"
              end
            end
          end
          return true
        end,
      },
    },
  },
}
