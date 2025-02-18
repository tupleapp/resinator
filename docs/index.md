---
title: Home
layout: home
nav_order: 1
---

Currently a dumping ground for various pieces of information related to `.rc` and `.res` files that I haven't found satisfying documentation for elsewhere. Might be organized into something more useful later.

## Random quirks of the MSVC++ `rc` tool

- Resource definitions that specify a filename can specify files in the include path of the `rc` compiler, e.g. `windows.h` and they will be found/used.

### CLI

- Multiple options can be specified at a time, e.g. `/vnl409` gets resolved as if it were `/v /n /l409`.
- The `/sl` option ('Specify the resource string length limit in percentage') must be between 1 and 100 (if specified). If it's set to 100, the maximum length of a string literal becomes 8192.
  + The `rc` tool will crash if `/sl 100` is set and there is a string literal with exactly 8193 characters in it. If one more character is added to the string literal, it errors with 'string literal too long'.
  + The default maximum string literal length (if `/sl` is not specified) is 4097. If `/sl 50` is specified, the maximum string literal length becomes 4096 rather than 4097. So, there's no `/sl` setting that's equivalent to the default string literal length limit.
  + If `/sl 33` is set, the maximum string literal length becomes 2703 (`8192 * 0.33 = 2,703.36`). 2704 chars will error with `string literal too long`.
  + If `/sl 15` is set, the maximum string literal length becomes 1228 (`8192 * 0.15 = 1,228.8`). 1229 chars will error with `string literal too long`.

#### Undocumented options

- `/a` seems to be a recognized option but it's unclear what it does and is totally undocumented AFAICT
- Either one of `/?c` or `/hc` will add a normally hidden 'Comments extracting switches:' section to the help menu, with `/t` and `/t`-prefixed options dealing with `.LCX` and `.LCE` files. Can find no info about any of this online. A generated `.LCE` file seems to be an XML file with some info about the comments and resources in the `.rc` file(s).
- `/p` will output the preprocessed version of the `.rc` file to `<filename>.rcpp` *instead of* outputting a `.res` file (i.e. it will only run the preprocessor).
  + There doesn't appear to be any way to control the name of the `.rcpp` file (`/fo` does not affect it)
- `/s <unknown>` will insert a bunch of resources with name `HWB` into the `.res`. I can't find any info on this except a note [on this page](https://learn.microsoft.com/en-us/cpp/windows/how-to-create-a-resource-script-file?view=msvc-170) saying that `HWB` is a resource name that is reserved by Visual Studio. The option seems to need a value but the value doesn't seem to have any affect on the `.res` contents and it seems to accept any value without complaint.
- `/z` seems to always error with `fatal error RC1212: invalid option - /z argument missing substitute font name`. Not sure what type of value it's looking for, or what it would affect if it were provided a valid value.
  + A value with `/` in it seems to get past the `argument missing substitute font name` error and will allow `rc.exe` to compile successfully.

## Common Resource Attributes / Memory Flags

### Flags

| Attribute | Value |
|-----------|-------|
| `MOVEABLE` | `0x10` |
| `SHARED` | `0x20` |
| `PURE` | `0x20` |
| `PRELOAD` | `0x40` |
| `DISCARDABLE` | `0x1000` |

### [`RT_`](https://learn.microsoft.com/en-us/windows/win32/menurc/resource-types) Default Flags

{: .note }
> Default values use the flags directly rather than 'applying' the relevant Common Resource Attribute(s), and therefore can have values that are not possible when specifying memory flags via Common Resource Attributes.

| Default | Types |
|----|---------|
| `MOVEABLE | DISCARDABLE` | `RT_ICON`, `RT_CURSOR` |
| `MOVEABLE | SHARED` | `RT_RCDATA`, `RT_BITMAP`, `RT_HTML`, `RT_ACCELERATOR` |
| `MOVEABLE | SHARED | DISCARDABLE` | `RT_GROUP_ICON`, `RT_GROUP_CURSOR`, `RT_STRING`, `RT_FONT`, `RT_DIALOG` |
| `MOVEABLE | PRELOAD` | `RT_FONTDIR` |

### Common Resource Attribute effects

| Attribute | Effect |
|-----------|--------|
| `PRELOAD` | `flags | PRELOAD` |
| `LOADONCALL` | `flags & ~PRELOAD` |
| `MOVEABLE` | `flags | MOVEABLE` |
| `FIXED` | `flags & ~(MOVEABLE | DISCARDABLE)` |
| `SHARED` | `flags | SHARED` |
| `NONSHARED` | `flags & ~(SHARED | DISCARDABLE)` |
| `PURE` | `flags | PURE` |
| `IMPURE` | `flags & ~(PURE | DISCARDABLE)` |
| `DISCARDABLE` | `flags | (DISCARDABLE | MOVEABLE | SHARED)` |

## `ACCELERATORS` resource

- Warning on `SHIFT` or `CONTROL` without `VIRTKEY`
- Warning on 'ASCII character not equivalent to virtual key code' (example: `"^C", 1, VIRTKEY`)
- If both `ASCII` and `VIRTKEY` are specified, `VIRTKEY` always takes precedence
- Things that differ or are unclear from the [documentation](https://learn.microsoft.com/en-us/windows/win32/menurc/accelerators-resource):
  + `options` and `type` can be intermixed, there is no enforced ordering
  + All parts of an accelerator require commas between them
  + "When VIRTKEY is specified and event contains a string, event ~~must be~~ *[will be transformed to be]* uppercase."
- Some notes about how `event` is compiled:
  + `"^^"` -> `^`
  + `"ab"` -> `ba`
  + `"aba"` (any > 2 char long string) -> invalid accelerator

## `DIALOG` and `DIALOGEX` resources

- [The Old New Thing: `DIALOG`](https://devblogs.microsoft.com/oldnewthing/20040621-00/?p=38793)
- [The Old New Thing: `DIALOGEX`](https://devblogs.microsoft.com/oldnewthing/20040623-00/?p=38753)

### `DIALOGEX`

| Size/Type | Description |
|-----------|--------|
| `u16` | Dialog version (1 for `DIALOGEX`) |
| `u16` | `0xFFFF` for `DIALOGEX` |
| `u32` | Help ID |
| `u32` | Extended style |
| `u32` | Style |
| `u16` | Number of controls |
| `u16` | X |
| `u16` | Y |
| `u16` | Width |
| `u16` | Height |
| `NameOrOrdinal` | Menu |
| `NameOrOrdinal` | Dialog class |
| Null-teriminated UTF-16 String | Title |

- Multiple of each optional statement is allowed, and the last one specified takes precedence, with the exception of `CLASS` and `MENU` (see below).

#### `CLASS` and `MENU` quirks

- `MENU` is a proper `NameOrOrdinal`, in that it can be unquoted, contain " within it, etc.
  + However, it is parsed differently than a `NameOrOrdinal` used for resource id/types. Whenever the first character is a number, it is treated as a number. Anything after that is treated as a digit with the value `<UTF-16 code unit> - '0'` (where `'0'` is `0x30`, and using wrapping underflow for ascii values < 0x30). Some examples:
    - `3200` -> `3200` (ordinal)
    - `1+1` -> `51` (ordinal)
    - `1|2` -> `862` (ordinal)
    - `1a2` -> `592` (ordinal)
    - `1a` -> `59` (ordinal)
    - `1A` -> `27` (ordinal)
    - `1!` -> `65531` (ordinal)
    - `0Œ` -> `0x122` (ordinal, `Œ` is `U+0152`, so `- 0x30` is `0x122`)
    - `0<U+10002>` -> `0x49F2` (ordinal, `<U+10002>` is `0xD800 0xDC02` in UTF-16, so `0xD800 - 0x30` is `0xD7D0`, multiplied by 10 (with wrapping overflow) that is `0x6E20`, then `0xDC02 - 0x30` is `0xDBD2`, added to `0x6E20` (wrapping on overflow) is `0x49F2`)
    - `1PleaseDon'tInterpretThisAsANumber` -> `28404` (ordinal)
    - `3200-1600` -> `24848` (ordinal)
    - `3200-1600+1` -> `59919` (ordinal)
    - `(3200-1600)` -> `(3200-1600)` (string)
- If `CLASS` or `MENU` is specified first as an ordinal with in a resource, then any more `CLASS` or `MENU` optional statements will also be treated as an ordinal, e.g. `1 DIALOGEX 1,2,3,4 CLASS 1 CLASS "this would normally be a string" {}` will result in a resource with a class of `47959` as an ordinal.
- `CLASS` must be either a number, number expression, or a quoted string literal. If a quoted string is to be interpretted as a number due to the quirk in the previous point, then it is parsed first and then uses the same evaluation as `MENU` outlined above.

#### `FONT`

- If a `FONT` optional statement is present, `DS_SETFONT` (`0x40`) is implied
- `italic` setting of a `FONT` statement is a number evaluated as a `u16` and then interpretted as a boolean (so `65536` overflows to 0 which is interpretted as `FALSE`, and so is `65536L` [but `65537` overflows to 1 which is `TRUE`]).
- `charset` setting of a `FONT` statement is truncated to a `u8`.
- The comma between `point_size` and `typeface` parameters of `FONT` is optional (and can also be > 1), e.g. `FONT 1 "name"` is valid and so is `FONT 1,, ,, "name"`. The commas between the rest of the parameters are required and there can only be exactly 1 between those parameters.

## `BITMAP` resource

- Win32 RC compiler allows any DIB with header size >= 40 or exactly 12 (Win 2.0). DIBs with unknown or `BITMAPV4HEADER`/`BITMAPV5HEADER` headers will fail to be loaded at runtime by LoadBitmap/LoadImage, but they are not a compile error.
- Does not support PNG at all. Side note: If a `.png` file is specified in a `.xml` file run through `uicc.exe`, it will generate a `.rc` file with e.g. `<id> IMAGE "image.png"` which is a custom resource with the type as the string `IMAGE`, while for `.bmp` files it will use `BITMAP`.
- Win32 `rc.exe` will always try to write `numColorPaletteBytes` (`<number of bytes per color palette index> * numColors`) bytes to the `.res`, filling in any bytes past the end of the file with the pixel data (this is a miscompilation I believe), and then `0x00` if it starts reading past the end of the file (note: `numColors` is `biClrUsed` from the `BITMAPINFOHEADER`).
  + If `numColorPaletteBytes` is >= 2 GiB, then `rc.exe` will fail with `out of memory`, e.g. if `numColors` is `0x262C8ACF`, then `rc.exe` will attempt to allocate `0x98B22B3C` bytes (2.386 GiB) and fail.
    - Certain values where `numColorPaletteBytes` is >= 2 GiB seem avoid the `out of memory` and have extremely long runtime (it seems like an infinite loop but will eventually finish), but I'm not sure exactly what the conditions are that avoid the `out of memory`.
  + If `numColorPaletteBytes` is < 2 GiB, then `rc.exe` will succeed (but may take a while)
- Win32 `rc.exe` will miscompile bitmaps where the `bfOffBits` field of the bitmap file header is set larger than `<the size of the bmp file> + <size of the DIB header>`, in which case the 'size' of the resource will become negative and a resource with the size set to the underflowed size (e.g. `-1` will underflow/wrap to `0xFFFFFFFF`) but with no actual data.

## Input and output code pages

- It's possible to get the Win32 compiler to be in a weird state where it starts writing UTF-8 encoded bytes for ASCII string data. This seems to depend on the order of `#pragma code_page` directives in a file and/or the code page given on the CLI.
  + A Windows-1252 encoded file that has only `1 RCDATA { "Ó" }` in it will (with all default settings) be compiled into the single byte `0xD3` (`Ó` in Windows-1252). If the option `/c65001` is given to the CLI, it will instead be compiled into `0xEF 0xBF 0xBD`, the UTF-8 sequence for `U+FFFD` (the replacement character).
  + A Windows-1252 encoded file that has `1 RCDATA { "Ó" }` with `#pragma code_page(1252)` before it will be compiled into the single byte `0xD3` (`Ó` in Windows-1252). If the option `/c65001` is given to the CLI, it will instead be compiled into `0xC3 0x93`, the UTF-8 sequence for `Ó`.
    + The `/c65001` behavior can be 'counteracted' if there is any `#pragma code_page` before the `#pragma code_page(1252)` (it will compile into `0xD3` again).
  + A Windows-1252 encoded file that has `1 RCDATA { "Ó" }` with `#pragma code_page(65001)` before it will be compiled into the single byte `0x3F` (the `?` character). If the option `/c65001` is given to the CLI, it will instead be compiled into `0xEF 0xBF 0xBD`, the UTF-8 sequence for `U+FFFD` (the replacement character).
    + The `/c65001` behavior can be triggered without using the `/c` option if there is any `#pragma code_page` before the `#pragma code_page(65001)`
  + It seems like there are actually two distinct settings: input code page and output code page. The first `#pragma code_page` does not affect the output code page, but all the rest do. The `/c` CLI option affects both.