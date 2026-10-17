package msdf_font

// 示例共用的离线 MSDF 资产。默认嵌入；自定义 prefix 对应同名 PNG 与 JSON。
import "core:encoding/json"
import "core:fmt"
import "core:os"

import foster "olib:foster"

load :: proc(device: ^foster.GraphicsDevice, prefix := "") -> (font: foster.MsdfFont, texture: foster.Texture, ok: bool) {
	if device == nil do return
	png := #load("ui.png")
	metadata := #load("ui.json")
	if prefix != "" {
		png_error, json_error: os.Error
		png, png_error = os.read_entire_file(fmt.tprintf("%s.png", prefix), context.temp_allocator)
		metadata, json_error = os.read_entire_file(fmt.tprintf("%s.json", prefix), context.temp_allocator)
		if png_error != nil || json_error != nil do return
	}
	info: struct {
		atlas: struct {
			type: string,
			yOrigin: string,
			width, height: int,
		},
	}
	if json.unmarshal(metadata, &info, allocator = context.temp_allocator) != nil ||
	   info.atlas.type != "msdf" || info.atlas.yOrigin != "top" {
		return
	}
	image := foster.ImageFromEncoded(png)
	if image.Width <= 0 || image.Width != info.atlas.width || image.Height != info.atlas.height {
		foster.ImageDispose(&image)
		return
	}
	font = foster.MsdfFontMake(image, metadata)
	font.OwnsImage = true
	if font.Size <= 0 || font.DistanceRange <= 0 || len(font.Characters) == 0 {
		foster.MsdfFontDispose(&font)
		return
	}
	texture = foster.TextureFromImage(device, &font.Image, "offline MSDF font")
	if texture.Resource == nil {
		foster.MsdfFontDispose(&font)
		return
	}
	ok = true
	return
}
