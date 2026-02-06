# Apex Unwrap Filter (Lua, Pandoc JSON)

This repository contains a small **Lua-based AST filter** for
[Apex](https://github.com/ApexMarkdown/apex) that **unwraps certain block
elements** so they are not wrapped in an extra `<p>` tag after rendering.

It uses the same **Pandoc JSON filter** protocol described in the
[Pandoc filter documentation](https://pandoc.org/filters.html#summary), so it
can also be used directly with Pandoc.

## What it does

The filter operates on the Pandoc JSON AST and performs two related
transformations:

- **Angle‑prefixed paragraphs**: Any paragraph whose text begins with
  `< ` (a left angle bracket followed by a space) is treated as
  preformatted/HTML. The paragraph is converted from:

  ```json
  { "t": "Para", "c": [ ... inlines ... ] }
  ```

  into a:

  ```json
  { "t": "RawBlock", "c": ["html", "< ..."] }
  ```

  This removes the wrapping `<p>` tag while preserving any surrounding
  container, such as a block quote.

- **Single‑image paragraphs**: Any paragraph whose only inline is an
  `Image` is unwrapped into a bare `<img>` tag. This is useful for
  figure‑style constructs where you do not want a `<p>` wrapping the
  image.

In both cases, the filter only ever removes a wrapping paragraph; it does
not change whether the content is inside a block quote, div, or other
container.

## Installation (Apex)

Once this filter is published in the central directory, you will be able
to install it automatically with:

```bash
apex --install-filter unwrap
```

This will clone the repository into your user filters directory:

- `$XOWNS_CONFIG_HOME/apex/filters/unwrap` or
- `~/.config/apex/filters/unwrap`

After installation, you can enable the filter with:

```bash
apex --filter unwrap input.md > output.html
```

You can also run the Lua script directly from anywhere using the
`--lua-filter` flag:

```bash
apex --lua-filter /path/to/unwrap.lua input.md > output.html
```

## Manual installation

If you prefer to install manually:

1. Ensure you have a Lua interpreter and the `dkjson` JSON library
   available. On macOS with Homebrew Lua, a typical setup is:

   ```bash
   brew install luarocks
   luarocks install dkjson
   ```
2. Copy `unwrap.lua` into your filters directory:

   ```bash
   mkdir -p ~/.config/apex/filters
   cp unwrap.lua ~/.config/apex/filters/unwrap
   chmod +x ~/.config/apex/filters/unwrap
   ```

3. Run Apex with the filter:

   ```bash
   apex --filter unwrap input.md > output.html
   ```

## Usage (Pandoc)

Because this is a standard Pandoc JSON filter, you can also use it with
Pandoc:

```bash
pandoc input.md -t json \
  | lua unwrap.lua \
  | pandoc -f json -t html -o output.html
```

## Implementation notes

The filter:

1. Reads the entire Pandoc JSON document from `stdin` using `dkjson`.
2. Walks the `blocks` array recursively:
   - Inside containers like `BlockQuote`, it rewrites only the child
     blocks, so the block quote itself is preserved.
3. For each block:
   - If it is a paragraph starting with `< `, it is converted to a
     `RawBlock "html"` using the concatenated inline text.
   - If it is a paragraph containing exactly one `Image` inline, it is
     converted to a `RawBlock "html"` that renders a single `<img>`
     element, preserving:
     - the image URL and title,
     - the alt text (from the image inlines),
     - any id, classes, or key‑value attributes from the Pandoc `Attr`
       triple.
4. Writes the modified JSON document to `stdout`.

