local Helpers = {}

-- Linear Interpolation helper
function Helpers.lerp(startVal, endVal, elapsed, duration)
    if duration <= 0 then return endVal end
    local t = elapsed / duration
    if t > 1 then t = 1 end
    return startVal + (endVal - startVal) * t
end

-- Clear print output of nested and other complex tables
function Helpers.dumpTable(t, label)

    local topLabelLen = 0
    if label then
        local topLabel = string.format("\n================= %s =================", tostring(label))
        topLabelLen = #topLabel - 1
        print(topLabel)
    end

    if type(t) ~= "table" then
        print("dumpTable error: Expected table, got " .. type(t) .. " (" .. tostring(t) .. ")")
        if label then
            print(string.rep("=", topLabelLen))
        end
        return
    end

    local function recurse(tbl, indent, visited)
        visited = visited or {}
        if visited[tbl] then
            print(indent .. "<circular reference>")
            return
        end
        visited[tbl] = true

        local keys = {}
        for k in pairs(tbl) do keys[#keys + 1] = k end

        -- Handle empty tables explicitly
        if #keys == 0 then
            print(indent .. "<empty table>")
            return
        end

        table.sort(keys, function(a, b)
            local ta = type(tbl[a]) == "table" and 1 or 0
            local tb = type(tbl[b]) == "table" and 1 or 0
            if ta ~= tb then return ta < tb end
            return tostring(a) < tostring(b)
        end)

        for _, k in ipairs(keys) do
            local v = tbl[k]
            if type(v) == "table" then
                print(indent .. tostring(k) .. ":")
                recurse(v, indent .. "  ", visited)
            else
                print(indent .. tostring(k) .. " = " .. tostring(v))
            end
        end
    end

    recurse(t, "")

    if label then
        print(string.rep("=", topLabelLen))
    end
end

-- Internal helper to parse XML attributes
local function parseArgs(s)
    local arg = {}
    string.gsub(s, "([%w_:]+)%s*=%s*([\"'])(.-)%2", function(w, _, a)
        arg[w] = a
    end)
    return arg
end


function Helpers.xmlToTable(xmlString)
    local stack = {}
    local top = {}
    table.insert(stack, top)
    local i, j = 1, 1
    
    while true do
        local ni, nj, closing, label, xarg, empty = string.find(xmlString, "<(%/?)([%w_:]+)(.-)(%/?)>", i)
        if not ni then break end
        
        -- Handle text content between tags
        local text = string.sub(xmlString, i, ni - 1)
        if not string.find(text, "^%s*$") then
            -- If we have text content, store it in a special key
            top.xmlTextContent = (top.xmlTextContent or "") .. text
        end
        
        if empty == "/" then -- Self-closing tag <tag />
            local node = parseArgs(xarg)
            -- If parent already has this key, turn it into a list
            if top[label] then
                if not top[label][1] then top[label] = { top[label] } end
                table.insert(top[label], node)
            else
                top[label] = node
            end
            
        elseif closing == "" then -- Start tag <tag>
            local node = parseArgs(xarg)
            table.insert(stack, node)
            -- Track hierarchy
            node.parentRef = top 
            node.labelRef = label
            top = node
            
        else -- End tag </tag>
            local toClose = table.remove(stack)
            top = stack[#stack]
            
            -- Clean up the text content
            if toClose.xmlTextContent then
                toClose.xmlTextContent = toClose.xmlTextContent:match("^%s*(.-)%s*$")
            end
            
            local currentLabel = toClose.labelRef
            toClose.parentRef = nil
            toClose.labelRef = nil

            -- LOGIC: If the node has NO attributes and NO children, reduce it to a simple value
            local isComplex = false
            for k, v in pairs(toClose) do
                if k ~= "xmlTextContent" then isComplex = true break end
            end
            
            local value = toClose
            if not isComplex and toClose.xmlTextContent then
                value = toClose.xmlTextContent
            end
            
            -- Insert into parent
            if top[currentLabel] then
                if type(top[currentLabel]) ~= "table" or (type(top[currentLabel]) == "table" and not top[currentLabel][1]) then
                    top[currentLabel] = { top[currentLabel] } -- Convert existing single item to list
                end
                table.insert(top[currentLabel], value)
            else
                top[currentLabel] = value
            end
        end
        i = nj + 1
    end
    
    -- The XML root is usually the single key in the top container
    for k, v in pairs(top) do return v end
end

-- Convert all the stringified numbers to strings in a table.
-- This is common for tables returned from XML or JSON parsing.
function Helpers.convertTableTypes(tbl, overrides)
    local DEFAULT_KEYWORDS = {
        "NAME", "TEXT", "LABEL", "ID", "VERSION", "STATUS", "DESCRIPTION"
    }

    local protectedList = (type(overrides) == "table" and #overrides > 0) 
                          and overrides 
                          or DEFAULT_KEYWORDS

    local protected = {}
    for _, word in ipairs(protectedList) do
        protected[word:upper()] = true
    end

    local function process(t)
        for k, v in pairs(t) do
            if (type(v) == "table") then
                process(v)
            elseif (type(v) == "string") then
                local upperKey = tostring(k):upper()
                local isProtected = false
                
                for word in pairs(protected) do
                    if (upperKey:find(word, 1, true)) then
                        isProtected = true
                        break
                    end
                end

                if (not isProtected) then
                    local lowerVal = v:lower()
                    
                    if (lowerVal == "true") then 
                        t[k] = true
                    elseif (lowerVal == "false") then 
                        t[k] = false
                    elseif (v:match("^%x%x%x%x%x%x$")) then
                        -- Keep Hex
                    elseif (v:match("^0%d+") and not v:match("^0%.") and v ~= "0") then
                        -- Keep Padded String
                    else
                        local num = tonumber(v)
                        if (num) then t[k] = num end
                    end
                end
            end
        end
    end

    process(tbl)
    return tbl
end

return Helpers