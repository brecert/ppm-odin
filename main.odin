//+vet
package main

import "core:os"
import "core:fmt"
import "core:bytes"
import "core:reflect"
import "core:mem/virtual"
import "core:math/bits"
import "core:encoding/endian"
import "core:hash/xxhash"

main :: proc() {
  ppm_path := os.args[1]

  file, err := virtual.map_file(ppm_path, {.Read})
  if err != virtual.Map_File_Error.None {
    fmt.eprintf("%v\n", err)
  }

  pos := 4
  read_type :: proc ($T: typeid) -> T {
    res := (^T)(bytes.ptr_from_bytes(file[pos:pos+size_of(T)]))
    pos += size_of(T)
    return res
  }

  hash_state, xerr := xxhash.XXH64_create_state()
  if xerr != nil {
    fmt.eprintf("%v\n", xerr)
  }

  header := (^Header)(bytes.ptr_from_bytes(file[pos:pos+size_of(Header)]))
  frame_count := header.frame_count + 1
  pos += size_of(Header)
  
  // metadata := (^Metadata)(bytes.ptr_from_bytes(file[pos:pos+size_of(Metadata)]));
  pos += size_of(Metadata)

  // metadata := (^Thumbnail)(bytes.ptr_from_bytes(file[pos:pos+size_of(Thumbnail)]));
  pos += size_of(Thumbnail)
  
  animation_header := (^AnimationHeader)(bytes.ptr_from_bytes(file[pos:pos+size_of(AnimationHeader)]))
  pos += size_of(AnimationHeader)

  frame_offset := transmute([]u32)file[pos:pos+(int(frame_count) * size_of(u32))]
  pos += len(frame_offset)

  frame_data_size := int(header.animation_data_size - size_of(animation_header) - u32(len(frame_offset)))
  frame_data := file[pos:pos+frame_data_size]
  pos += frame_data_size

  previous_layers: [2]Layer = {}

  for i := 0; i < int(frame_count); i += 1 {
    offset := frame_offset[i]
    
    frame_header := extract_frame_header(frame_data[offset])
    offset += 1
    
    translation: Maybe(^Translation)
    if (frame_header.is_translated) {
      translation = (^Translation)(bytes.ptr_from_bytes(frame_data[offset:offset+size_of(Translation)]))
      offset += size_of(Translation)
    }

    line_encodings: [2][Frame_Height]FrameLineEncoding

    for l := 0; l < 2; l += 1 {
      for y := 0; y < 48; y += 1 {
        byte := frame_data[offset]
        offset += 1
        for bit: u8 = 0; bit < 4; bit += 1 {
          line_encodings[l][y * 4 + int(bit)] = FrameLineEncoding((byte >> (bit * 2)) & 0b00000011)
        }
      }
    }
    
    layers: [2]Layer

    for l := 0; l < 2; l += 1 {
      for y := 0; y < Frame_Height; y += 1 {
        encoding := line_encodings[l][y]
        switch encoding {
          case .NoData: continue
          case .CompressedDefaultOne:
            if encoding == .CompressedDefaultOne {
              for x := 0; x < Frame_Width; x += 1 {
                layers[l][y][x] = true
              }
            }
            fallthrough
          case .Compressed:
            line_flags := endian.unchecked_get_u32be(frame_data[offset:offset+size_of(u32)])
            offset += size_of(u32)
            x := 0
            for line_flags != 0 {
              if line_flags & 0x80000000 != 0 {
                chunk := frame_data[offset]    
                offset += 1
                for bit: u8 = 0; bit < 8; bit += 1 {
                    layers[l][y][x] = ((chunk >> bit) & 0x1) != 0
                    x += 1
                }
              } else {
                x += 8
              }

              line_flags <<= 1;
            }

          case .Uncompressed:
            for x := 0; x < 32; x += 1 {
              chunk := frame_data[offset]
              offset += 1
              for bit: u8 = 0; bit < 8; bit += 1 {
                  layers[l][y][(x * 8) + int(bit)] = ((chunk >> bit) & 0x1) != 0
              }
            }
        }
      }
    }

    if frame_header.is_keyframe {
      previous_layers = layers
    } else {
      for l := 0; l < 2; l += 1 {
        for y := 0; y < Frame_Height; y += 1 {
          previous_layers[l][y] ~= layers[l][y]
        }
      }
    }

    colors := []u32{
      paper_color_hex(frame_header.paper_color),
      pen_color_hex(frame_header.layer_1_pen, frame_header.paper_color),
      pen_color_hex(frame_header.layer_2_pen, frame_header.paper_color),
    }
    
    if translation != nil {
      panic("translation is not handled")
    }
    for y := 0; y < Frame_Height; y += 1 {
      for x := 0; x < Frame_Width; x += 1 {
        pixel_1 := previous_layers[0][y][x]
        pixel_2 := previous_layers[1][y][x]
        color :=  colors[1] if (pixel_1) else colors[2] if (pixel_2) else colors[0]
        xxhash.XXH64_update(hash_state, reflect.as_bytes(color))
      }
    }
  }

  // WRITE FILE
  // f, ferr := os.open("image.pbm", os.O_CREATE | os.O_RDWR | os.O_TRUNC)
  // if ferr != os.ERROR_NONE {
  //   panic("ow")
  // }
  // defer os.close(f)
  // os.write_string(f, "P5 256 192 1\n")
  // for y := 0; y < Frame_Height; y += 1 {
  //   for x := 0; x < Frame_Width; x += 1 {
  //     os.write_byte(f, 1 if previous_layers[0][y][x] else 0)
  //   }
  // }
  // _ = os.read;
  
  fmt.printf("%v\n", xxhash.XXH64_digest(hash_state))
}

Header :: struct {
  animation_data_size: u32,
  sound_data_size: u32,
  frame_count: u16,
  format_version: u16,
}

Lock :: enum u16 {
  Unlocked,
  Locked
}

Metadata :: struct #packed {
  lock: Lock,
  thumbnail_index: u16,
  original_author: [11]u16,
  previous_author: [11]u16,
  current_author: [11]u16,
  previous_author_id: [8]u8,
  current_author_id: [8]u8,
  original_filename: [18]u8,
  current_filename: [18]u8,
  original_author_id: [8]u8,
  file_id: [8]u8,
  last_modified: u32,
  _padding: u16,
}

Thumbnail_Width :: 64
Thumbnail_Height :: 48

Thumbnail :: struct {
  data: [(Thumbnail_Width * Thumbnail_Height) / 2]u8,
}

AnimationFlags :: struct {
  loop: bool,
  layer_1_visible: bool,
  layer_2_visible: bool,
}

AnimationHeader :: struct {
  table_size: u16,
  _padding: [4]u8,
  flags: u16,
}

extract_animation_header_flags :: proc(flags: u16) -> AnimationFlags {
  // right to left
  return AnimationFlags { 
    loop = bits.bitfield_extract(flags, 16 - 2, 1) == 1,
    layer_1_visible = bits.bitfield_extract(flags, 16 - 5, 1) == 1,
    layer_2_visible = bits.bitfield_extract(flags, 16 - 6, 1) == 1,
  }
}

PaperColor :: enum u8 {
  Black,
  White
}

paper_color_inverse :: proc (color: PaperColor) -> (result: PaperColor) {
  switch color {
    case .Black:
      result = .White
    case .White:
      result = .Black
  }
  return
}

paper_color_hex :: proc(color: PaperColor) -> (result: u32) {
  switch color {
    case .Black:
      result = 0x0E0E0E
    case .White:
      result = 0xFFFFFF
  }
  return
}

PenColor :: enum u8 {
  InverseOfPaperUnused, 
  InverseOfPaper,
  Red,
  Blue,
}

pen_color_hex :: proc(pen_color: PenColor, paper_color: PaperColor) -> (result: u32) {
  switch pen_color {
    case .InverseOfPaperUnused, .InverseOfPaper: 
      result = paper_color_hex(paper_color_inverse(paper_color))
    case .Red:
      result = 0xFF2A2A
    case .Blue:
      result = 0x0A39FF
  }
  return
}

FrameHeader :: struct {
  paper_color: PaperColor,
  layer_1_pen: PenColor,
  layer_2_pen: PenColor,
  is_translated: bool,
  is_keyframe: bool,
}

extract_frame_header :: proc(flags: u8) -> FrameHeader {
  // 0b1 00 10 01 1
  //    7  5  3  1 0 
  return FrameHeader { 
    paper_color = PaperColor(bits.bitfield_extract(flags, 0, 1)),
    layer_1_pen = PenColor(bits.bitfield_extract(flags, 1, 2)),
    layer_2_pen = PenColor(bits.bitfield_extract(flags, 3, 2)),
    is_translated = bits.bitfield_extract(flags, 5, 2) != 0,
    is_keyframe = bits.bitfield_extract(flags, 7, 1) == 1,
  }
}

Translation :: struct {
  x: i8,
  y: i8
}

FrameLineEncoding :: enum u8 {
  NoData,
  Compressed,
  CompressedDefaultOne,
  Uncompressed,
}

Frame :: struct {
  header: FrameHeader,
  layers: [2]Layer,
  translation: Maybe(Translation)
}

Frame_Width :: 256
Frame_Height :: 192
Layer :: [Frame_Height][Frame_Width]bool

import "core:testing"

@(test)
extract_animation_header_flags_works :: proc(t: ^testing.T) {
  flags := extract_animation_header_flags(0x4700)
  testing.expect_value(t, flags.loop, true)
  testing.expect_value(t, flags.layer_1_visible, false)
  testing.expect_value(t, flags.layer_1_visible, false)
}

@(test)
extract_frame_header_works :: proc(t: ^testing.T) {
  flags := extract_frame_header(0b10010011)
  testing.expect_value(t, flags.paper_color, PaperColor.White)
  testing.expect_value(t, flags.layer_1_pen, PenColor.InverseOfPaper)
  testing.expect_value(t, flags.layer_2_pen, PenColor.Red)
  testing.expect_value(t, flags.is_translated, false)
  testing.expect_value(t, flags.is_keyframe, true)
}