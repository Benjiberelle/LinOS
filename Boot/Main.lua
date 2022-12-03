 
local function getComponentAddress(name)
	return component.list(name)() or error("A component is missing " .. name .. " Something is missing")
end

local EEPROMAddress, InternetAddress, GPUAdress = 
         getComponentAddress("eeprom")
         getComponentAddress("internet")
         getComponentAddress("gpu")


component.invoke(GPUAdress, "bind", getComponentAddress("screen"))
local screenWidth, screenHeight = component.invoke(GPUAdress,  "getResolution")


local function centrize(width)
    return math.floor(screenWidth / 2 -width / 2)
end
local function  centrizedText(y, color, text)
	component.invoke(GPUAddress, "fill", 1, y, screenWidth, 1, " ")
	component.invoke(GPUAddress, "setForeground", color)
	component.invoke(GPUAddress, "set", centrize(#text), y, text)
end

local function title()
	local y = math.floor(screenHeight / 2 - 1)
	centrizedText(y, 0x2D2D2D, "LinOS")

	return y + 2
end

local function status(text, needWait)
	centrizedText(title(), 0x878787, text)

	if needWait then
		repeat
			needWait = computer.pullSignal()
		until needWait == "key_down" or needWait == "touch"
	end
end

local function progress(value)
	local width = 26
	local x, y, part = centrize(width), title(), math.ceil(width * value)
	
	component.invoke(GPUAddress, "setForeground", 0x878787)
	component.invoke(GPUAddress, "set", x, y, string.rep("─", part))
	component.invoke(GPUAddress, "setForeground", 0xC3C3C3)
	component.invoke(GPUAddress, "set", x + part, y, string.rep("─", width - part))
end

local function filesystemPath(path)
	return path:match("^(.+%/).") or ""
end

local function filesystemName(path)
	return path:match("%/?([^%/]+%/?)$")
end

local function filesystemHideExtension(path)
	return path:match("(.+)%..+") or path
end

local function rawRequest(url, chunkHandler)
	local internetHandle, reason = component.invoke(internetAddress, "request", repositoryURL .. url:gsub("([^%w%-%_%.%~])", function(char)
		return string.format("%%%02X", string.byte(char))
	end))

	if internetHandle then
		local chunk, reason
		while true do
			chunk, reason = internetHandle.read(math.huge)	
			
			if chunk then
				chunkHandler(chunk)
			else
				if reason then
					error("Oops.. The internet request failed: " .. tostring(reason))
				end

				break
			end
		end

		internetHandle.close()
	else
		error("COops.. The Connection failed: " .. url)
	end
end

local function request(url)
	local data = ""
	
	rawRequest(url, function(chunk)
		data = data .. chunk
	end)

	return data
end

local function download(url, path)
	selectedFilesystemProxy.makeDirectory(filesystemPath(path))

	local fileHandle, reason = selectedFilesystemProxy.open(path, "wb")
	if fileHandle then	
		rawRequest(url, function(chunk)
			selectedFilesystemProxy.write(fileHandle, chunk)
		end)

		selectedFilesystemProxy.close(fileHandle)
	else
		error("We can't open this file: " .. tostring(reason))
	end
end

local function deserialize(text)
	local result, reason = load("return " .. text, "=string")
	if result then
		return result()
	else
		error(reason)
	end
end

component.invoke(GPUAddress, "setBackground", 0xE1E1E1)
component.invoke(GPUAddress, "fill", 1, 1, screenWidth, screenHeight, " ")

for address in component.list("filesystem") do
	local proxy = component.proxy(address)
	if proxy.spaceTotal() >= 2 * 1024 * 1024 then
		temporaryFilesystemProxy, selectedFilesystemProxy = proxy, proxy
		break
	end
end

if not temporaryFilesystemProxy then
	status("A HDD is missing, Please put it one and reboot", true)
	return
end

progress(0)
local files = deserialize(request(installerURL .. "Files.cfg"))

for i = 1, #files.installerFiles do
	progress(i / #files.installerFiles)
	download(files.installerFiles[i], installerPath .. files.installerFiles[i])
end


package = {loading = {}, loaded = {}}

function require(module)
	if package.loaded[module] then
		return package.loaded[module]
	elseif package.loading[module] then
		error("The module is already loading " .. module .. ": " .. debug.traceback())
	else
		package.loading[module] = true

		local handle, reason = temporaryFilesystemProxy.open(installerPath .. "Libraries/" .. module .. ".lua", "rb")
		if handle then
			local data, chunk = ""
			repeat
				chunk = temporaryFilesystemProxy.read(handle, math.huge)
				data = data .. (chunk or "")
			until not chunk

			temporaryFilesystemProxy.close(handle)
			
			local result, reason = load(data, "=" .. module)
			if result then
				package.loaded[module] = result() or true
			else
				error(reason)
			end
		else
			error("We can't open this file: " .. tostring(reason))
		end

		package.loading[module] = nil

		return package.loaded[module]
	end
end
