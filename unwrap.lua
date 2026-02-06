-- apex-filter-unwrap: remove wrapping <p> for certain blocks
--
-- This Lua filter consumes / produces Pandoc-style JSON, as used by Apex.
-- It:
--   - Unwraps paragraphs whose text starts with "< " into raw HTML blocks
--   - Unwraps paragraphs that contain only a single Image into a bare <img>
--
-- The latter is useful for figure-like containers where you don't want
-- an extra <p> around the image.

-- JSON dependency: dkjson
-- This filter expects the Lua JSON module "dkjson" to be available.
-- On macOS/Homebrew Lua, you can typically install it with:
--   brew install luarocks
--   luarocks install dkjson
local ok, json = pcall(require, "dkjson")
if not ok then
  io.stderr:write(
    "apex-filter-unwrap: missing Lua dependency 'dkjson'.\n",
    "Install it, for example:\n",
    "  brew install luarocks\n",
    "  luarocks install dkjson\n"
  )
  os.exit(1)
end

-- Read entire stdin
local function read_all()
  local chunks = {}
  while true do
    local chunk = io.read(4096)
    if not chunk then break end
    table.insert(chunks, chunk)
  end
  return table.concat(chunks)
end

-- Concatenate a list of inlines into a plain string, best-effort.
-- Returns nil if we hit something we don't know how to stringify.
local function concat_inlines_plain(inlines)
  local parts = {}
  for _, inline in ipairs(inlines or {}) do
    if inline.t == "Str" then
      table.insert(parts, inline.c)
    elseif inline.t == "SoftBreak" or inline.t == "LineBreak" then
      table.insert(parts, "\n")
    elseif inline.t == "RawInline" and type(inline.c) == "table" then
      -- RawInline is ["format","text"]
      table.insert(parts, inline.c[2] or "")
    else
      -- Unknown / rich inline; bail so we don't accidentally mangle content
      return nil
    end
  end
  return table.concat(parts)
end

-- Detect a paragraph whose text begins with "< " (angle + space)
local function is_angle_para(block)
  if not block or block.t ~= "Para" then
    return false
  end
  local inlines = block.c
  if type(inlines) ~= "table" or #inlines == 0 then
    return false
  end
  local first = inlines[1]
  if not first or first.t ~= "Str" or type(first.c) ~= "string" then
    return false
  end
  return first.c:match("^<") ~= nil
end

-- Convert a Pandoc Attr triple to id/class/other HTML attributes
local function attr_to_html(attr)
  local id   = attr[1]
  local classes = attr[2] or {}
  local kvs  = attr[3] or {}
  local attrs = {}

  if id and id ~= "" then
    table.insert(attrs, string.format('id="%s"', id))
  end
  if #classes > 0 then
    table.insert(attrs, string.format('class="%s"', table.concat(classes, " ")))
  end
  for _, pair in ipairs(kvs) do
    local k, v = pair[1], pair[2]
    if k and v and k ~= "" then
      table.insert(attrs, string.format('%s="%s"', k, v))
    end
  end

  if #attrs == 0 then
    return ""
  end
  return " " .. table.concat(attrs, " ")
end

-- Build a RawBlock "html" containing a single <img> from an Image inline node
local function image_to_raw_block(image)
  if not image or image.t ~= "Image" then
    return nil
  end
  local attr  = image.c[1] or { "", {}, {} }
  local alt_inlines = image.c[2] or {}
  local target = image.c[3] or { "", "" }
  local src   = target[1] or ""
  local title = target[2] or ""
  local alt = concat_inlines_plain(alt_inlines) or ""
  local attr_html = attr_to_html(attr)
  local parts = {}
  table.insert(parts, "<img")
  if src ~= "" then
    table.insert(parts, string.format(' src="%s"', src))
  end
  if alt ~= "" then
    table.insert(parts, string.format(' alt="%s"', alt))
  end
  if title ~= "" then
    table.insert(parts, string.format(' title="%s"', title))
  end
  if attr_html ~= "" then
    table.insert(parts, attr_html)
  end
  table.insert(parts, " />")
  return {
    t = "RawBlock",
    c = { "html", table.concat(parts) },
  }
end

-- Strip leading "< " (and optional spaces) from inlines; return rest, or nil
local function strip_angle_prefix(inlines)
  if type(inlines) ~= "table" or #inlines == 0 then
    return nil
  end
  local i = 1
  local first = inlines[1]
  if not first or first.t ~= "Str" or type(first.c) ~= "string" or first.c:match("^<") == nil then
    return nil
  end
  i = 2
  while i <= #inlines do
    local el = inlines[i]
    if el.t == "Space" or el.t == "SoftBreak" or el.t == "LineBreak" then
      i = i + 1
    else
      break
    end
  end
  local rest = {}
  for j = i, #inlines do
    table.insert(rest, inlines[j])
  end
  return rest
end

-- True if inlines are exactly one Image (ignoring trailing Space/SoftBreak/LineBreak)
local function is_single_image_inlines(inlines)
  if type(inlines) ~= "table" or #inlines == 0 then
    return false
  end
  if inlines[1].t ~= "Image" then
    return false
  end
  for i = 2, #inlines do
    local el = inlines[i]
    if el.t ~= "Space" and el.t ~= "SoftBreak" and el.t ~= "LineBreak" then
      return false
    end
  end
  return true
end

-- Turn a paragraph that starts with "< " into a RawBlock "html"
local function unwrap_angle_para(block)
  local inlines = block.c or {}
  local rest = strip_angle_prefix(inlines)
  if rest and is_single_image_inlines(rest) then
    local raw = image_to_raw_block(rest[1])
    if raw then
      return raw
    end
  end
  local text = concat_inlines_plain(inlines)
  if not text then
    return block
  end
  return {
    t = "RawBlock",
    c = { "html", text },
  }
end

-- Detect a paragraph that contains exactly one Image inline
local function is_single_image_para(block)
  if not block or block.t ~= "Para" then
    return false
  end
  local inlines = block.c
  if type(inlines) ~= "table" or #inlines ~= 1 then
    return false
  end
  local first = inlines[1]
  return first and first.t == "Image"
end

-- Turn a paragraph containing only an Image into a bare <img>
local function unwrap_image_para(block)
  return image_to_raw_block(block.c[1]) or block
end

-- Recursively walk a list of blocks, unwrapping where appropriate
local function walk_blocks(blocks)
  if type(blocks) ~= "table" then
    return blocks
  end

  local out = {}

  for _, blk in ipairs(blocks) do
    -- Recurse into container blocks first (Pandoc: BlockQuote c=[blocks], Div c=[attr,blocks], Figure c=[attr,caption,blocks])
    if blk.t == "BlockQuote" and type(blk.c) == "table" then
      blk.c = walk_blocks(blk.c)
    elseif blk.t == "Div" and type(blk.c) == "table" and #blk.c >= 2 then
      blk.c[2] = walk_blocks(blk.c[2])
    elseif blk.t == "Figure" and type(blk.c) == "table" and #blk.c >= 3 then
      blk.c[3] = walk_blocks(blk.c[3])
    end

    -- Angle-prefixed paragraphs
    if is_angle_para(blk) then
      blk = unwrap_angle_para(blk)
    -- Single-image paragraphs
    elseif is_single_image_para(blk) then
      blk = unwrap_image_para(blk)
    end

    table.insert(out, blk)
  end

  return out
end

-- Main
local input = read_all()
local doc, pos, err = json.decode(input, 1, nil)
if not doc then
  io.stderr:write("apex-filter-unwrap: JSON decode error: ", tostring(err), "\n")
  os.exit(1)
end

if doc.blocks then
  doc.blocks = walk_blocks(doc.blocks)
end

local encoded = json.encode(doc, { indent = false })
io.write(encoded)
io.output():flush()
