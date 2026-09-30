extends MeshInstance3D

# Flat test floor with a generated checker texture. The checker is not
# decoration: without a ground reference you cannot feel whether you are actually
# gaining speed, which is the entire thing this project is testing.

@export var tile_size := 2.0
@export var dark := Color(0.16, 0.17, 0.19)
@export var light := Color(0.42, 0.44, 0.47)


func _ready() -> void:
	var plane := mesh as PlaneMesh
	if plane == null:
		push_error("TestFloor expects a PlaneMesh")
		return

	var px := 64
	var img := Image.create(px, px, false, Image.FORMAT_RGB8)
	for y in px:
		for x in px:
			# Bit shifts, not division: avoids an integer-division warning and
			# gives 32px cells, i.e. 2x2 checks per texture tile.
			var cell := ((x >> 5) + (y >> 5)) & 1
			img.set_pixel(x, y, dark if cell == 0 else light)

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = ImageTexture.create_from_image(img)
	mat.roughness = 0.95
	mat.metallic = 0.0
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.uv1_scale = Vector3(plane.size.x / tile_size, plane.size.y / tile_size, 1.0)
	material_override = mat
