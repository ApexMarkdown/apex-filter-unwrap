-- apex-filter-unwrap: remove wrapping <p> for certain blocks
--
-- This Lua filter consumes / produces Pandoc-style JSON, as used by Apex.
-- It:
--   - Unwraps paragraphs whose text starts with "< " into raw HTML blocks
--   - Unwraps paragraphs that contain only a single Image into a bare <img>
--
-- The latter is useful for figure-like containers where you don't want
-- an extra <p> around the image.

local json = require("dkjson")

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
  return first.c:match("^<%s") ~= nil
end

-- Turn a paragraph that starts with "< " into a RawBlock "html"
local function unwrap_angle_para(block)
  local text = concat_inlines_plain(block.c or {})
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

-- Turn a paragraph containing only an Image into a bare <img>
local function unwrap_image_para(block)
  local image = block.c[1]
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

  local html = table.concat(parts)

  return {
    t = "RawBlock",
    c = { "html", html },
  }
end

-- Recursively walk a list of blocks, unwrapping where appropriate
local function walk_blocks(blocks)
  if type(blocks) ~= "table" then
    return blocks
  end

  local out = {}

  for _, blk in ipairs(blocks) do
    -- Recurse into container blocks first
    if blk.t == "BlockQuote" or blk.t == "Div" or blk.t == "Figure" then
      if type(blk.c) == "table" then
        blk.c = walk_blocks(blk.c)
      end
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

