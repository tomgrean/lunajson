local byte = string.byte
local char = string.char
local find = string.find
local gsub = string.gsub
local len = string.len
local match = string.match
local sub = string.sub
local concat = table.concat
local tonumber = tonumber

local band, bor
if _VERSION == 'Lua 5.2' then
	band = bit32.band
elseif type(bit) == 'table' then
	band = bit.band
else
	band = function(v, mask) -- mask must be 2^n-1
		return v % (mask+1)
	end
end

local function newparser(src, saxtbl)
	local _
	local json, jsonnxt
	local jsonlen, pos, acc = 0, 1, 0

	local doparse

	-- initialize
	local function nop() end

	if type(src) == 'string' then
		json = src
		jsonlen = len(json)
		jsonnxt = function()
			json = ''
			jsonlen = 0
			jsonnxt = nop
		end
	else
		jsonnxt = function()
			acc = acc + jsonlen
			pos = 1
			repeat
				json = src()
				if not json then
					json = ''
					jsonlen = 0
					jsonnxt = nop
					return
				end
				jsonlen = len(json)
			until jsonlen > 0
		end
		jsonnxt()
	end

	local sax_startobject = saxtbl.startobject
	local sax_key = saxtbl.key
	local sax_endobject = saxtbl.endobject
	local sax_startarray = saxtbl.startarray
	local sax_endarray = saxtbl.endarray
	local sax_string = saxtbl.string
	local sax_number = saxtbl.number
	local sax_boolean = saxtbl.boolean
	local sax_null = saxtbl.null

	-- helper
	local function parseerror(errmsg)
		error("parse error at " .. acc + pos .. ": " .. errmsg)
	end

	local function tellc()
		local c = byte(json, pos)
		if c then
			return c
		end
		jsonnxt()
		c = byte(json, pos)
		if c then
			return c
		end
		parseerror("unexpected termination")
	end

	local function spaces()
		while true do
			_, pos = find(json, '^[ \n\r\t]*', pos)
			if pos ~= jsonlen then
				pos = pos+1
				return
			end
			if jsonlen == 0 then
				parseerror("unexpected termination")
			end
			jsonnxt()
		end
	end

	-- parse constants
	local function generic_constant(target, targetlen, ret, sax_f)
		for i = 1, targetlen do
			local c = tellc()
			if byte(target, i) ~= c then
				parseerror("invalid char")
			end
			pos = pos+1
		end
		if sax_f then
			return sax_f(ret)
		else
			return
		end
	end

	local function f_nul()
		local str = sub(json, pos, pos+2)
		if str == 'ull' then
			pos = pos+3
			if sax_null then
				return sax_null(nil)
			else
				return
			end
		end
		return generic_constant('ull', 3, nil, sax_null)
	end

	local function f_fls()
		local str = sub(json, pos, pos+3)
		if str == 'alse' then
			pos = pos+4
			if sax_boolean then
				return sax_boolean(false)
			else
				return
			end
		end
		return generic_constant('alse', 4, false, sax_boolean)
	end

	local function f_tru()
		local str = sub(json, pos, pos+2)
		if str == 'rue' then
			pos = pos+3
			if sax_boolean then
				return sax_boolean(true)
			else
				return
			end
		end
		return generic_constant('rue', 3, true, sax_boolean)
	end

	-- parse numbers
	local radixmark = match(tostring(0.5), '[^0-9]')
	local fixedtonumber = tonumber
	if radixmark ~= '.' then
		if find(radixmark, '%W') then
			radixmark = '%' .. radixmark
		end
		fixedtonumber = function(s)
			return tonumber(gsub(s, '.', radixmark))
		end
	end

	local function generic_number(mns)
		local newpos

		local str = ''
		repeat
			_, newpos = find(json, '^[-+0-9.eE]*', pos)
			str = str .. sub(json, pos, newpos)
			pos = newpos
			if pos ~= jsonlen then
				pos = pos+1
				break
			end
			jsonnxt()
		until jsonlen == 0

		local c = byte(str)
		if c == 0x30 then
			_, newpos = find(str, '^%.[0-9]+', 2)
		elseif 0x30 < c and c < 0x3A then
			_, newpos = find(str, '^[0-9]*%.?[0-9]*', 2)
			if byte(str, newpos) == 0x2E then
				parseerror('invalid number')
			end
		else
			parseerror('invalid number')
		end

		c = byte(str, newpos+1)
		if c == 0x45 or c == 0x65 then
			_, newpos = find(str, '^[+-]?[0-9]+', newpos+2)
		end

		if newpos ~= len(str) then
			parseerror('invalid number')
		end
		local num = fixedtonumber(str)
		if mns then
			num = -num
		end
		if sax_number then
			return sax_number(num)
		end
	end

	local function cont_number(mns, newpos)
		local expc = byte(json, newpos+1)
		if expc == 0x45 or expc == 0x65 then -- e or E?
			_, newpos = find(json, '^[+-]?[0-9]+', newpos+2)
		end
		newpos = newpos or jsonlen
		if newpos ~= jsonlen then
			local num = fixedtonumber(sub(json, pos-1, newpos))
			pos = newpos+1
			if mns then
				num = -num
			end
			if sax_number then
				return sax_number(num)
			else
				return
			end
		end
		pos = pos-1
		return generic_number(mns)
	end

	local function f_zro(mns)
		local _, newpos = find(json, '^%.[0-9]+', pos)
		if newpos then
			return cont_number(mns, newpos)
		end
		if sax_number then
			return sax_number(0)
		end
	end

	local function f_num(mns)
		local _, newpos = find(json, '^[0-9]*%.?[0-9]*', pos)
		if byte(json, newpos) ~= 0x2E then -- check that num is not ended by comma
			return cont_number(mns, newpos)
		end
		pos = pos-1
		return generic_number(mns)
	end

	local function f_mns()
		local c = byte(json, pos)
		if c then
			pos = pos+1
			if c > 0x30 then
				if c < 0x3A then
					return f_num(true)
				end
			else
				if c > 0x2F then
					return f_zro(true)
				end
			end
		end
		return generic_number(true)
	end

	-- parse strings
	local f_str_surrogateprev = 0

	local f_str_tbl = {
		['"']  = '"',
		['\\'] = '\\',
		['/']  = '/',
		['b']  = '\b',
		['f']  = '\f',
		['n']  = '\n',
		['r']  = '\r',
		['t']  = '\t'
	}

	local function f_str_subst(ch, rest)
		local u8
		if ch == 'u' then
			local l = len(rest)
			local ucode = match(rest, '^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]')
			if not ucode then
				parseerror("invalid unicode charcode")
			end
			ucode = tonumber(ucode, 16)
			rest = sub(rest, 5)
			if ucode < 0x80 then -- 1byte
				u8 = char(ucode)
			elseif ucode < 0x800 then -- 2byte
				u8 = char(0xC0 + ucode * 0.015625, 0x80 + band(ucode, 0x3F))
			elseif ucode < 0xD800 or 0xE000 <= ucode then -- 3byte
				u8 = char(0xE0 + ucode * 0.000244140625, 0x80 + band(ucode * 0.015625, 0x3F), 0x80 + band(ucode, 0x3F))
			elseif 0xD800 <= ucode and ucode < 0xDC00 then -- surrogate pair 1st
				if f_str_surrogateprev == 0 then
					f_str_surrogateprev = ucode
					if l == 4 then
						return ''
					end
				end
			else -- surrogate pair 2nd
				if f_str_surrogateprev == 0 then
					f_str_surrogateprev = 1
				else
					ucode = 0x10000 + (f_str_surrogateprev - 0xD800) * 0x400 + (ucode - 0xDC00)
					f_str_surrogateprev = 0
					u8 = char(0xF0 + ucode * 0.000003814697265625, 0x80 + band(ucode * 0.000244140625, 0x3F), 0x80 + band(ucode * 0.015625, 0x3F), 0x80 + band(ucode, 0x3F))
				end
			end
		end
		if f_str_surrogateprev ~= 0 then
			parseerror("invalid surrogate pair")
		end
		return (u8 or f_str_tbl[ch] or parseerror("invalid escape sequence")) .. rest
	end

	local function f_str(iskey)
		local pos2 = pos
		local newpos
		local str = ''
		local bs
		while true do
			while true do
				newpos = find(json, '[\\"]', pos2)
				if newpos then
					break
				end
				str = str .. sub(json, pos, jsonlen)
				if pos2 == jsonlen+2 then
					pos2 = 2
				else
					pos2 = 1
				end
				jsonnxt()
			end
			if byte(json, newpos) == 0x22 then
				break
			end
			pos2 = newpos+2
			bs = true
		end
		str = str .. sub(json, pos, newpos-1)
		pos = newpos+1

		if bs then
			str = gsub(str, '\\(.)([^\\]*)', f_str_subst)
			if f_str_surrogateprev ~= 0 then
				decodeerror("invalid surrogate pair")
			end
		end

		if iskey then
			if sax_key then
				return sax_key(str)
			else
				return
			end
		else
			if sax_string then
				return sax_string(str)
			else
				return
			end
		end
	end

	-- parse arrays
	local function f_ary()
		if sax_startarray then
			sax_startarray()
		end
		spaces()
		if byte(json, pos) ~= 0x5D then
			local newpos
			while true do
				doparse()
				_, newpos = find(json, '^[ \n\r\t]*,[ \n\r\t]*', pos)
				if not newpos then
					_, newpos = find(json, '^[ \n\r\t]*%]', pos)
					if newpos then
						pos = newpos
						break
					end
					spaces()
					local c = byte(json, pos)
					if c == 0x2C then
						pos = pos+1
						spaces()
						newpos = pos-1
					elseif c == 0x5D then
						break
					else
						parseerror("no closing bracket of an array")
					end
				end
				pos = newpos+1
				if pos > jsonlen then
					spaces()
				end
			end
		end
		pos = pos+1
		if sax_endarray then
			return sax_endarray()
		end
	end

	-- parse objects
	local function f_obj()
		if sax_startobject then
			sax_startobject()
		end
		spaces()
		if byte(json, pos) ~= 0x7D then
			local newpos
			while true do
				if byte(json, pos) ~= 0x22 then
					parseerror("not key")
				end
				pos = pos+1
				f_str(true)
				_, newpos = find(json, '^[ \n\r\t]*:[ \n\r\t]*', pos)
				if not newpos then
					spaces()
					if byte(json, pos) ~= 0x3A then
						parseerror("no colon after a key")
					end
					pos = pos+1
					spaces()
					newpos = pos-1
				end
				pos = newpos+1
				if pos > jsonlen then
					spaces()
				end
				doparse()
				_, newpos = find(json, '^[ \n\r\t]*,[ \n\r\t]*', pos)
				if not newpos then
					_, newpos = find(json, '^[ \n\r\t]*}', pos)
					if newpos then
						pos = newpos
						break
					end
					spaces()
					local c = byte(json, pos)
					if c == 0x2C then
						pos = pos+1
						spaces()
						newpos = pos-1
					elseif c == 0x7D then
						break
					else
						parseerror("no closing bracket of an object")
					end
				end
				pos = newpos+1
				if pos > jsonlen then
					spaces()
				end
			end
		end
		pos = pos+1
		if sax_endobject then
			return sax_endobject()
		end
	end

	local dispatcher = {
		false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false,
		false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false,
		false, false, f_str, false, false, false, false, false, false, false, false, false, false, f_mns, false, false,
		f_zro, f_num, f_num, f_num, f_num, f_num, f_num, f_num, f_num, f_num, false, false, false, false, false, false,
		false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false,
		false, false, false, false, false, false, false, false, false, false, false, f_ary, false, false, false, false,
		false, false, false, false, false, false, f_fls, false, false, false, false, false, false, false, f_nul, false,
		false, false, false, false, f_tru, false, false, false, false, false, false, f_obj, false, false, false, false,
	}

	function doparse()
		local f = dispatcher[byte(json, pos)+1] -- byte(json, pos) is always available here
		if not f then
			parseerror("unknown value")
		end
		pos = pos+1
		f()
	end

	local function run()
		spaces()
		doparse()
	end

	local function isend()
		if pos > jsonlen then
			jsonnxt()
		end
	end

	local function seek(n)
		pos = pos+n
		while pos > jsonlen+1 do
			jsonnxt()
			if not json then
				parseerror("unexpected termination")
			end
			pos = pos-jsonlen
			jsonlen = len(json)
			jsonlen = len(json)
		end
	end

	local function read(n)
		local pos2 = pos+n
		while pos > jsonlen do
			json = jsonnxt()
			if not json then
				return parseerror("unexpected termination")
			end
			pos = pos-jsonlen
			jsonlen = len(json)
			jsonlen = len(json)
		end
	end

	return {
		run = run,
		read = read,
		skip = skip,
		tryc = tryc,
	}
end

local function newfileparser(fn, saxtbl)
	local fp = io.open(fn)
	local function gen()
		local s
		if fp then
			s = fp:read(1)
			if not s then
				fp:close()
				fp = nil
			end
		end
		return s
	end
	return newparser(gen, saxtbl)
end

return {
	newparser = newparser,
	newfileparser = newfileparser
}
