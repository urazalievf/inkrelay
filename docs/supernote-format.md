# Supernote `.note` format

How `Sources/InkRelayCore/Supernote/SupernoteNote.swift` reads Supernote notebooks. There is no official specification. This follows the format as community tools document it, and was checked against the Apache-2.0 sample notebooks in philips/supernote-typescript and against Supernote's own PDF exports of the same notebooks: 73–97% ink overlap, mean pixel difference 1–2.4 of 255. To rerun those comparisons, point `INKRELAY_SUPERNOTE_SAMPLES` at a folder of samples and run `swift test`.

## Container

- **Start:** the bytes `note` followed by a signature `SN_FILE_VER_YYYYNNNN`, such as `SN_FILE_VER_20230015`.
- **Footer:** the address of the footer block is the last 4 bytes of the file, little-endian.
- **Blocks:** each one is a little-endian 32-bit length followed by that many bytes.
- **Metadata blocks** are `<KEY:VALUE>` pairs. The footer lists the header, every `PAGE…` address, and more.

## Pages and layers

- **A page's metadata names its layers:** `MAINLAYER`, `LAYER1`–`LAYER3` and `BGLAYER` (the template).
- **Draw order and visibility:**
  - `LAYERSEQ` gives the order.
  - `LAYERINFO` is JSON with `#` written in place of `:`; it says which layers are hidden.
- **Page size:**
  - Manta (`N5`) is 1920 × 2560; other models are 1404 × 1872.
  - A page is landscape when `ORIENTATION` is 1090 or 1270.

## Bitmaps

Layers are `RATTA_RLE`: pairs of (colour code, length byte). See `RattaRLE` in the decoder.
- **Colour codes:**
  - 0x61 is black, 0x62 the transparent background, 0x65 white and 0x66 marker black.
  - The grays depend on the file's age:
    - From signature 20230015 on, 0x9D and 0x9E are dark gray (shade 0x9D), and 0xC9 and 0xCA light gray (shade 0xC9). 0x63 and 0x64 still appear for older strokes kept in a newer file, drawn darker (0x30 and 0x50).
    - Older files use 0x63 and 0x67 for dark gray (0x9D), and 0x64 and 0x68 for light gray (0xC9).
- **Lengths:**
  - A length byte `n` without the high bit is a run of `n + 1` pixels.
  - With the high bit set, it's the high part of a longer run, completed by the next pair of the same colour: `1 + n2 + ((n1 & 0x7F) + 1) << 7`. If the next pair is another colour, the held run stands alone as `((n1 & 0x7F) + 1) << 7`.
  - A held run at the very end is cut to what's left of the page.
- **The 0xFF length:**
  - normally a run of 0x4000 pixels;
  - 0x400 for the blank `style_white` template, whose background layer is 0x140E bytes long.

Converted PDFs go in `converted/`, and everything downstream reads those. `inkrelay convert NOTE PDF` runs the converter by hand.
