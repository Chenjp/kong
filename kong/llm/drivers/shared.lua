local _M = {}

-- imports
local cjson        = require("cjson.safe")
local http         = require("resty.http")
local utils        = require "kong.tools.utils"
local split        = utils.split
local fmt          = string.format
local os           = os
local string_match = string.match
--

local log_entry_keys = {
  REQUEST_BODY = "ai.payload.request",
  RESPONSE_BODY = "ai.payload.response",

  TOKENS_CONTAINER = "ai.usage",
  PROCESSING_TIME = "ai.usage.processing_time",

  REQUEST_MODEL = "ai.meta.request_model",
  RESPONSE_MODEL = "ai.meta.response_model",
  PROVIDER_NAME = "ai.meta.provider_name",
}

local openai_override = os.getenv("OPENAI_TEST_PORT")

_M.upstream_url_format = {
  openai = fmt("%s://api.openai.com:%s", (openai_override and "http") or "https", (openai_override) or "443"),
  anthropic = "https://api.anthropic.com:443",
  cohere = "https://api.cohere.com:443",
  azure = "https://%s.openai.azure.com:443/openai/deployments/%s",
}

_M.operation_map = {
  openai = {
    ["llm/v1/completions"] = {
      path = "/v1/completions",
      method = "POST",
    },
    ["llm/v1/chat"] = {
      path = "/v1/chat/completions",
      method = "POST",
    },
  },
  anthropic = {
    ["llm/v1/completions"] = {
      path = "/v1/complete",
      method = "POST",
    },
    ["llm/v1/chat"] = {
      path = "/v1/messages",
      method = "POST",
    },
  },
  cohere = {
    ["llm/v1/completions"] = {
      path = "/v1/generate",
      method = "POST",
    },
    ["llm/v1/chat"] = {
      path = "/v1/chat",
      method = "POST",
    },
  },
  azure = {
    ["llm/v1/completions"] = {
      path = "/completions",
      method = "POST",
    },
    ["llm/v1/chat"] = {
      path = "/chat/completions",
      method = "POST",
    },
  },
}

_M.clear_response_headers = {
  shared = {
    "Content-Length",
  },
  openai = {
    "Set-Cookie",
  },
  azure = {
    "Set-Cookie",
  },
  mistral = {
    "Set-Cookie",
  },
}

function _M.to_ollama(request_table, model)
  local input = {}

  if request_table.prompt and request_table.messages then
    return kong.response.exit(400, "cannot run raw 'prompt' and chat history 'messages' requests at the same time - refer to schema")

  elseif request_table.messages then
    input.messages = request_table.messages

  elseif request_table.prompt then
    input.prompt = request_table.prompt

  end

  -- common parameters
  input.stream = request_table.stream or false -- for future capability
  input.model = model.name

  if model.options then
    input.options = {}

    input.options.num_predict = request_table.num_predict or model.options.max_tokens
    input.options.temperature = request_table.temperature or model.options.temperature
    input.options.top_p = request_table.top_p or model.options.top_p
    input.options.top_k = request_table.top_k or model.options.top_k
  end

  return input, "application/json", nil
end

function _M.conf_from_request(kong_request, source, key)
  if source == "uri_captures" then
    return kong_request.get_uri_captures().named[key]
  elseif source == "headers" then
    return kong_request.get_header(key)
  elseif source == "query_params" then
    return kong_request.get_query_arg(key)
  else
    return nil, "source '" .. source .. "' is not supported"
  end
end

function _M.resolve_plugin_conf(kong_request, conf)
  local err
  local conf_m = utils.cycle_aware_deep_copy(conf)

  -- handle model name
  local model_m = string_match(conf_m.model.name or "", '%$%((.-)%)')
  if model_m then
    local splitted = split(model_m, '.')
    if #splitted ~= 2 then
      return nil, "cannot parse expression for field 'model.name'"
    end

    -- find the request parameter, with the configured name
    model_m, err = _M.conf_from_request(kong_request, splitted[1], splitted[2])
    if err then
      return nil, err
    end
    if not model_m then
      return nil, "'" .. splitted[1] .. "', key '" .. splitted[2] .. "' was not provided"
    end

    -- replace the value
    conf_m.model.name = model_m
  end

  -- handle all other options
  for k, v in pairs(conf.model.options or {}) do
    local prop_m = string_match(v or "", '%$%((.-)%)')
    if prop_m then
      local splitted = split(prop_m, '.')
      if #splitted ~= 2 then
        return nil, "cannot parse expression for field '" .. v .. "'"
      end

      -- find the request parameter, with the configured name
      prop_m, err = _M.conf_from_request(kong_request, splitted[1], splitted[2])
      if err then
        return nil, err
      end
      if not prop_m then
        return nil, splitted[1] .. " key " .. splitted[2] .. " was not provided"
      end

      -- replace the value
      conf_m.model.options[k] = prop_m
    end
  end

  return conf_m
end

function _M.from_ollama(response_string, model_info, route_type)
  local response_table, err = cjson.decode(response_string)
  if err then
    return nil, "failed to decode ollama response"
  end

  -- there is no direct field indicating STOP reason, so calculate it manually
  local stop_length = (model_info.options and model_info.options.max_tokens) or -1
  local stop_reason = "stop"
  if response_table.eval_count and response_table.eval_count == stop_length then
    stop_reason = "length"
  end

  local output = {}

  -- common fields
  output.model = response_table.model
  output.created = response_table.created_at

  -- analytics
  output.usage = {
    completion_tokens = response_table.eval_count or 0,
    prompt_tokens = response_table.prompt_eval_count or 0,
    total_tokens = (response_table.eval_count or 0) + 
                   (response_table.prompt_eval_count or 0),
  }

  if route_type == "llm/v1/chat" then
    output.object = "chat.completion"
    output.choices = {
      [1] = {
        finish_reason = stop_reason,
        index = 0,
        message = response_table.message,
      }
    }

  elseif route_type == "llm/v1/completions" then
    output.object = "text_completion"
    output.choices = {
      [1] = {
        index = 0,
        text = response_table.response,
      }
    }

  else
    return nil, "no ollama-format transformer for response type " .. route_type

  end

  return cjson.encode(output)
end

function _M.pre_request(conf, request_table)
  -- process form/json body auth information
  local auth_param_name = conf.auth and conf.auth.param_name
  local auth_param_value = conf.auth and conf.auth.param_value
  local auth_param_location = conf.auth and conf.auth.param_location
  
  if auth_param_name and auth_param_value and auth_param_location == "body" then
    request_table[auth_param_name] = auth_param_value
  end

  if conf.logging and conf.logging.log_statistics then
    kong.log.set_serialize_value(log_entry_keys.REQUEST_MODEL, conf.model.name)
    kong.log.set_serialize_value(log_entry_keys.PROVIDER_NAME, conf.model.provider)
  end

  -- if enabled AND request type is compatible, capture the input for analytics
  if conf.logging and conf.logging.log_payloads then
    kong.log.set_serialize_value(log_entry_keys.REQUEST_BODY, kong.request.get_raw_body())
  end

  return true, nil
end

function _M.post_request(conf, response_string)
  if conf.logging and conf.logging.log_payloads then
    kong.log.set_serialize_value(log_entry_keys.RESPONSE_BODY, response_string)
  end

  -- analytics and logging
  if conf.logging and conf.logging.log_statistics then
    -- check if we already have analytics in this context
    local request_analytics = kong.ctx.shared.analytics

    -- create a new structure if not
    if not request_analytics then
      request_analytics = {
        prompt_tokens = 0,
        completion_tokens = 0,
        total_tokens = 0,
      }
    end

    local response_object, err = cjson.decode(response_string)
    if err then
      return nil, "failed to decode response from JSON"
    end

    -- this captures the openai-format usage stats from the transformed response body
    if response_object.usage then
      if response_object.usage.prompt_tokens then
        request_analytics.prompt_tokens = (request_analytics.prompt_tokens + response_object.usage.prompt_tokens)
      end
      if response_object.usage.completion_tokens then
        request_analytics.completion_tokens = (request_analytics.completion_tokens + response_object.usage.completion_tokens)
      end
      if response_object.usage.total_tokens then
        request_analytics.total_tokens = (request_analytics.total_tokens + response_object.usage.total_tokens)
      end
    end

    -- update context with changed values
    kong.ctx.shared.analytics = request_analytics
    for k, v in pairs(request_analytics) do
      kong.log.set_serialize_value(fmt("%s.%s", log_entry_keys.TOKENS_CONTAINER, k), v)
    end

    kong.log.set_serialize_value(log_entry_keys.RESPONSE_MODEL, response_object.model or kong.ctx.plugin.llm_model_requested)
  end

  return nil
end

function _M.http_request(url, body, method, headers, http_opts)
  local httpc = http.new()

  if http_opts.http_timeout then
    httpc:set_timeouts(http_opts.http_timeout)
  end

  if http_opts.proxy_opts then
    httpc:set_proxy_options(http_opts.proxy_opts)
  end

  local res, err = httpc:request_uri(
    url,
    {
      method = method,
      body = body,
      headers = headers,
      ssl_verify = http_opts.https_verify,
    })
  if not res then
    return nil, "request failed: " .. err
  end

  return res, nil
end

return _M
