local boundary = require("boundary")
local timer = require("timer")
local http = require("http")
local json = require("json")
local fs = require("fs")

local nodeName, authKey, previous, current, conversions, requests, param

-- base64
-- encoding username and password for basic auth
function base64(data)
    local b='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    return ((data:gsub('.', function(x)
        local r,b='',x:byte()
        for i=8,1,-1 do r=r..(b%2^i-b%2^(i-1)>0 and '1' or '0') end
        return r
    end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
    if (#x < 6) then return '' end
        local c=0
        for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
        return b:sub(c+1,c+1)
    end)..({ '', '==', '=' })[#data%3+1])
end

-- lookup
-- use an array of attrs to drill down through nested tables to retrieve a value
function lookup(table, attrs)
    local v = table
    for i, a in ipairs(attrs) do
        if (type(v) == "table") then
            v = v[a]
        else
            return nil
        end
    end
    return v
end
 
-- tail
-- make a shallow copy of all but first element of array
function tail(a)
    local t = {}
    for i, v in ipairs(a) do
        if i > 1 then table.insert(t, v) end
    end
    return t
end

-- fnFactory returns a function(current, previous) that when called
-- will output the metric string ready for printing
--      name - name of metric
--      func - type of metric (diff, cur or ratio)
--      format - printf type format specifier for the result eg "%d"
--      params - parameters specific to build the required function
function fnFactory(name, func, format, params)
    local mask = "RABBITMQ_" .. name .. " " .. format .. " %s\n"
    local str = function(v) return string.format(mask, v, nodeName) end

    return ({
        -- diff calculates the difference between a current and previous values
        diff = function (attrs, scale)
            return function (c, p)
                local v = lookup(c, attrs)
                local w = lookup(p, attrs)
                if (type(v) == "number" and type(w) == "number") then
                    return str((scale or 1) * (v - w))
                else
                    return ""
                end
            end
        end,
        -- cur returns a current value
        cur = function (attrs, scale)
            return function (c)
                local v = lookup(c, attrs)
                if (type(v) == "number") then
                    return str((scale or 1) * v)
                else
                    return ""
                end
            end
        end,
        -- ratio takes values a and b from the current data and returns a/b
        ratio = function (attrs1, attrs2, scale)
            return function (c)
                local v = lookup(c, attrs1)
                local w = lookup(c, attrs2)
                if (type(v) == "number" and type(w) == "number") then
                    return str((scale or 1) * v / w)
                else
                    return ""
                end
            end
        end
    })[func](table.unpack(params))
end

-- processRequest takes a table of requests processes them in order
-- (recursively) and finally calls the callback funtion
function processRequest(reqs, callback)
    if (#reqs == 0) then
        callback()
    else
        local data = ""
        local r = reqs[1]
        local req = http.request({
            host = param.rabbitMQHost,
            port = param.rabbitMQPort,
            headers = { Authorization = authKey },
            path = "/api/" .. r.name
        }, function (res)
            res:on("end", function ()
                current[r.name] = r.handler(json.parse(data))
                processRequest(tail(reqs), callback)
            end)
            res:on("data", function (chunk)
                data = data .. chunk
            end)
        end)
        req:done()
    end
end

-- poll
-- function to poll tre server and print results
function poll()
    previous = current
    current = {}
    processRequest(requests, function()
        local t = {}
        for i, f in ipairs(conversions) do
            table.insert(t, f(current, previous))
        end
        fs.writeSync(1, -1, table.concat(t))
    end)
end

-- setup

-- set default parameters if not found in param.json
param = boundary.param or {
    pollInterval = 5000,
    rabbitMQHost = "127.0.0.1",
    rabbitMQPort = "15672",
    rabbitMQUser = "guest",
    rabbitMQPass = "guest"
}

-- build a table of functions to convert metrics into strings
conversions = {}
for i, v in ipairs({
    {"CONNECTIONS", "cur", "%d", {{"connections", "total"}}},
    {"CONNECTIONS_NOTRUNNING", "cur", "%d", {{"connections", "notrunning"}}},
    {"OCTETS_RECEIVED", "diff", "%d", {{"connections", "recv"}}},
    {"OCTETS_SENT", "diff", "%d", {{"connections", "send"}}},
    {"MESSAGES", "cur", "%d", {{"overview", "messages"}}},
    {"MESSAGES_READY", "cur", "%d", {{"overview", "messages_ready"}}},
    {"MESSAGES_UNACKNOWLEDGED", "cur", "%d", {{"overview", "messages_unacknowledged"}}},
    {"PROC_USED", "cur", "%d", {{"nodes", "proc_used"}}},
    {"MEM_USED", "cur", "%d", {{"nodes", "mem_used"}}},
    {"FD_USED", "cur", "%d", {{"nodes", "fd_used"}}},
    {"SOCKETS_USED", "cur", "%d", {{"nodes", "sockets_used"}}}
}) do
    table.insert(conversions, fnFactory(table.unpack(v)))
end

-- build table of requests and associated handler function
requests = {
    { name = "connections", handler = function(json)
        local stats = {total = 0, notrunning = 0, recv = 0, send = 0 }
        for i, v in ipairs(json) do
            stats.total = stats.total + 1
            if (v.state ~= "running") then
                stats.notrunning = stats.notrunning + 1
            end
            stats.recv = stats.recv + v.recv_oct
            stats.send = stats.send + v.send_oct
        end
        return stats
    end },
    { name = "overview", handler = function (json)
        return json.queue_totals
    end },
    { name = "nodes", handler = function (json)
        nodeName = json[1].name     -- set nodeName for printing
        return json[1]
    end }
}

-- create the basic auth key for the api http requests
authKey = "Basic " .. base64(param.rabbitMQUser .. ":" .. param.rabbitMQPass)

-- go

print("_bevent:Boundary RabbitMQ plugin up : version 1.0|t:info|tags:lua,rabbitmq,plugin")

poll()
timer.setInterval(param.pollInterval, poll)

