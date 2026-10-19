package main

import "core:fmt"
import foster "olib:foster"

main :: proc() {
	packer := foster.PackerMake()
	img := foster.ImageMake(4, 4, foster.Transparent)
	foster.ImageSetPixel(&img, 1, 1, foster.White)
	_ = foster.PackerAdd(&packer, "one", img)
	packer.PowerOfTwo = true
	out := foster.PackerPack(&packer)

	json := `{"atlas":{"size":16,"distanceRange":4},"metrics":{"lineHeight":1.25,"ascender":0.9,"descender":-0.2},"glyphs":[{"unicode":65,"advance":0.6,"planeBounds":{"left":0,"top":-0.8,"right":0.5,"bottom":0.1},"atlasBounds":{"left":1,"top":2,"right":9,"bottom":12}}]}`
	msdf := foster.MsdfFontMake(img, transmute([]u8)json)
	fmt.println("packed pages:", len(out.Pages), "msdf glyphs:", len(msdf.Characters))
}
