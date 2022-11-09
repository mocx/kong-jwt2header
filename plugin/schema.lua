local typedefs = require "kong.db.schema.typedefs"
local url = require "socket.url"

return {
  name = "kong-to-loki",
  fields = {
    { protocols = typedefs.protocols },
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
            {  graphql_uri = { type = "string", default = "/graphql" }, },
            {  flush_timeout = { type = "number", default = 2 }, },
            {  http_endpoint = typedefs.url({ required = false, encrypted = true }) }, -- encrypted = true is a Kong-Enterprise exclusive feature, does nothing in Kong CE
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
            --{ custom_fields_by_lua = typedefs.lua_code },          
        },
      },
    },
  },
}
