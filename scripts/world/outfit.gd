## Dresses a character model built on a GameData.MODELS profile (the hero body): the Classic way.
## A "look" is {"skins": {slot: skin name}, "weapon": model name, "shoulders": model name}:
##   skins    each body slot (MODELS.*.skins.slots: head, chest, legs, feet, hands) shows that
##            skin's texels (assets/<model>_skin_<skin>.png) over the base body, composited into
##            one texture (cached per combination, so everyone in the same gear shares one);
##   weapon   weapon_<name>.glb through the closed fist (a blend shape: the rig has no fingers);
##   shoulders shoulder_<name>.glb on both shoulders, mirrored;
##   armor    {slot: set}: modelled armour pieces (assets/armor_<set>.glb, tools/import_armor.py),
##            skinned meshes moved onto the character's own skeleton, so they bend with it; the body
##            texels each piece covers (armor_<set>_cover.png) are cut out of the body (alpha
##            scissor), so the body never pokes through.
## Used by players (from their equipment), NPCs (GameData.NPCS outfits) and armed monsters.
class_name Outfit
extends RefCounted

static var _skin_cache := {}
static var _region_masks := {}
static var _armor_scenes := {}
static var _cover_masks := {}

const ARMOR_SLOTS := ["head", "shoulders", "chest", "hands", "legs", "feet"] # bit order of the cover maps


## Applies `look` to `model` (the node holding the instanced character). Returns the attachment
## nodes it created, for the caller to free before dressing again.
static func dress(model: Node3D, profile: Dictionary, look: Dictionary) -> Array[Node]:
	var made: Array[Node] = []
	var armor: Dictionary = look.get("armor", {})
	_apply_skins(model, profile, look.get("skins", {}), armor)
	var skels := model.find_children("*", "Skeleton3D", true, false)
	if skels.is_empty():
		return made # model not loaded
	var skel: Skeleton3D = skels.front()
	_wear_armor(skel, armor, made)
	var weapon: String = look.get("weapon", "")
	_close_fist(model, profile.fist, weapon != "")
	if weapon != "":
		_attach(model, skel, profile.fist.bone, "res://assets/weapon_%s.glb" % weapon, _fist_in_model(model, skel, profile.fist), made)
	var shoulders: String = look.get("shoulders", "")
	if shoulders != "" and profile.has("shoulders"):
		var sh: Dictionary = profile.shoulders
		for i in range(sh.bones.size()):
			var at: Vector3 = _bone_in_model(model, skel, sh.at[i]).origin + Vector3.UP * float(sh.lift)
			var side := signf(at.x) if absf(at.x) > 0.001 else 1.0
			at.x += side * float(sh.out)
			var basis := Basis.from_scale(Vector3(side, 1, 1))  # authored for the +X side; mirror the other
			_attach(model, skel, sh.bones[i], "res://assets/shoulder_%s.glb" % shoulders, Transform3D(basis, at), made)
	return made


## The same skin on every body slot (an NPC's whole outfit, face included).
static func whole(profile: Dictionary, skin: String) -> Dictionary:
	var skins := {}
	for slot in profile.skins.slots:
		skins[slot] = skin
	return skins


## The same armour set on every slot.
static func whole_armor(armor_set: String) -> Dictionary:
	var armor := {}
	if armor_set != "":
		for slot in ARMOR_SLOTS:
			armor[slot] = armor_set
	return armor


## A set's skin on the body slots it paints: chest, legs, and the leg inside its boots ({slot:
## set}, as worn: a mixed outfit takes each slot's own set).
static func armor_skins(armor: Dictionary) -> Dictionary:
	var skins := {}
	for slot in ["chest", "legs", "feet"]:
		if armor.has(slot):
			skins[slot] = armor[slot]
	return skins


## The character's own body mesh (not an armour piece dressed onto it).
static func _body_mesh(model: Node3D) -> MeshInstance3D:
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		if not mi.has_meta("outfit_piece"):
			return mi
	return null


static func _apply_skins(model: Node3D, profile: Dictionary, skins: Dictionary, armor: Dictionary) -> void:
	var mi := _body_mesh(model)
	if mi == null or not profile.has("skins"):
		return
	var key: String = profile.path
	var names := []
	for slot in profile.skins.slots:
		names.append(skins.get(slot, ""))
	var worn := []
	for slot in ARMOR_SLOTS:
		worn.append(armor.get(slot, ""))
	var cache_key: String = key + "|" + ",".join(names) + "|" + ",".join(worn)
	if not _skin_cache.has(cache_key):
		var base_mat := mi.mesh.surface_get_material(0) as BaseMaterial3D
		var img := _pixels(base_mat.albedo_texture, Image.FORMAT_RGBA8)
		var masks := _masks_for(profile, img.get_size())
		var i := 0
		for slot in profile.skins.slots:
			var skin: String = names[i]
			i += 1
			if skin == "":
				continue
			var path: String = key.get_basename() + "_skin_%s.png" % skin
			if not ResourceLoader.exists(path):
				continue
			var src := _pixels(load(path), Image.FORMAT_RGBA8)
			if src.get_size() != img.get_size():
				src.resize(img.get_width(), img.get_height())
			for r in profile.skins.slots[slot]:
				if masks.has(r):
					img.blend_rect_mask(src, masks[r], Rect2i(Vector2i.ZERO, img.get_size()), Vector2i.ZERO) # src alpha: armour (bare skin painted by the retexture is 0, so the body shows)
		var mat := base_mat.duplicate() as BaseMaterial3D
		var hidden := false
		for slot in armor:
			var cover := _cover_for(armor[slot], slot, img.get_size())
			if cover:
				img.blit_rect_mask(Image.create(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8), cover, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i.ZERO)
				hidden = true
		if hidden:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			mat.alpha_scissor_threshold = 0.5
		mat.albedo_texture = ImageTexture.create_from_image(img)
		_skin_cache[cache_key] = mat
	mi.set_surface_override_material(0, _skin_cache[cache_key])


## Mask (alpha 255 where hidden) of the body texels an armour piece covers, at `size`.
static func _cover_for(armor_set: String, slot: String, size: Vector2i) -> Image:
	var key := "%s|%s|%s" % [armor_set, slot, size]
	if _cover_masks.has(key):
		return _cover_masks[key]
	var path := "res://assets/armor_%s_cover.png" % armor_set
	var bit := ARMOR_SLOTS.find(slot)
	var mask: Image = null
	if bit >= 0 and ResourceLoader.exists(path):
		var src := _pixels(load(path), Image.FORMAT_R8)
		mask = _mask(src, -1, bit)
		if mask:
			mask.resize(size.x, size.y, Image.INTERPOLATE_NEAREST)
	_cover_masks[key] = mask
	return mask


## Modelled armour: each worn piece's skinned mesh, moved onto this character's skeleton (the
## pieces are skinned to the same bones and bind pose, tools/import_armor.py).
static func _wear_armor(skel: Skeleton3D, armor: Dictionary, made: Array[Node]) -> void:
	for slot in armor:
		var path := "res://assets/armor_%s.glb" % armor[slot]
		if not ResourceLoader.exists(path):
			continue
		if not _armor_scenes.has(path):
			_armor_scenes[path] = load(path)
		var inst: Node = _armor_scenes[path].instantiate()
		var src := inst.find_child("armor_" + slot, true, false) as MeshInstance3D
		if src:
			var mi := MeshInstance3D.new()
			mi.name = "armor_" + slot
			mi.mesh = src.mesh
			mi.skin = src.skin
			mi.set_meta("outfit_piece", true)
			mi.visible = OS.get_environment("THORNHILL_ARMOR_BODY_ONLY") == "" # import check: what the body hides
			if OS.get_environment("THORNHILL_ARMOR_TINT") != "": # import check: each slot its own colour
				var m := (src.mesh.surface_get_material(0) as BaseMaterial3D).duplicate() as BaseMaterial3D
				m.albedo_color = Color.from_hsv(ARMOR_SLOTS.find(slot) / 6.0, 0.6, 1.0)
				mi.material_override = m
			skel.add_child(mi)
			mi.skeleton = NodePath("..")
			made.append(mi)
		inst.free()


## A texture's pixels, decompressed (imported textures are VRAM-compressed) in `format`.
static func _pixels(tex: Texture2D, format: Image.Format) -> Image:
	var img := tex.get_image()
	img.decompress()
	img.convert(format)
	return img


## One alpha mask per body region, from the region map (red channel = region index).
static func _masks_for(profile: Dictionary, size: Vector2i) -> Dictionary:
	var path: String = profile.skins.regions
	if _region_masks.has(path):
		return _region_masks[path]
	var src := _pixels(load(path), Image.FORMAT_R8)
	if src.get_size() != size:
		src.resize(size.x, size.y, Image.INTERPOLATE_NEAREST)
	var masks := {}
	for r in range(8):
		var m := _mask(src, r, -1)
		if m:
			masks[r] = m
	_region_masks[path] = masks
	return masks


## An alpha mask (255 where it matches) of a one-channel image: the texels equal to `value`, or
## with bit `bit` set; null where nothing matches.
static func _mask(src: Image, value: int, bit: int) -> Image:
	var data := src.get_data()
	var out := PackedByteArray()
	out.resize(data.size() * 4)
	var any := false
	for i in range(data.size()):
		if (data[i] == value) if bit < 0 else bool((data[i] >> bit) & 1):
			out[i * 4 + 3] = 255
			any = true
	return Image.create_from_data(src.get_width(), src.get_height(), false, Image.FORMAT_RGBA8, out) if any else null


## A rigid model hung on a bone, placed by a transform given in model space (metres, unscaled):
## auto-rigged skeletons are often in centimetres with a 0.01 node scale the attachment inherits,
## so the maths is done in model space and converted into the bone's space here.
static func _attach(model: Node3D, skel: Skeleton3D, bone_name: String, scene_path: String, in_model: Transform3D, made: Array[Node]) -> void:
	if skel.find_bone(bone_name) < 0 or not ResourceLoader.exists(scene_path):
		return
	var att := BoneAttachment3D.new()
	att.bone_name = bone_name
	skel.add_child(att)
	made.append(att)
	var inst: Node3D = load(scene_path).instantiate()
	att.add_child(inst)
	inst.transform = _bone_in_model(model, skel, bone_name).affine_inverse() * in_model


## A bone's rest transform in model space.
static func _bone_in_model(model: Node3D, skel: Skeleton3D, bone_name: String) -> Transform3D:
	var skel_in_model := model.global_transform.affine_inverse() * skel.global_transform
	return skel_in_model * skel.get_bone_global_rest(skel.find_bone(bone_name))


static func _close_fist(model: Node3D, fist: Dictionary, closed: bool) -> void:
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		var i: int = mi.find_blend_shape_by_name(fist.shape)
		if i >= 0:
			mi.set_blend_shape_value(i, 1.0 if closed else 0.0)


## The fist's grip frame (stored in bind-pose mesh space by the importer) in model space at rest:
## the same rest * bind transform the skinning applies to the hand's vertices. The handle runs
## through the fist: blade out of the thumb side, edge towards the knuckles.
static func _fist_in_model(model: Node3D, skel: Skeleton3D, fist: Dictionary) -> Transform3D:
	var bone := skel.find_bone(fist.bone)
	var bind := Transform3D()
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		var sk: Skin = mi.skin
		if sk == null:
			continue
		for i in range(sk.get_bind_count()):
			if sk.get_bind_bone(i) == bone or sk.get_bind_name(i) == fist.bone:
				bind = sk.get_bind_pose(i)
	var to_model := _bone_in_model(model, skel, fist.bone) * bind
	var axis: Vector3 = (to_model.basis * fist.axis).normalized()
	var edge: Vector3 = to_model.basis * fist.edge
	edge = (edge - axis * axis.dot(edge)).normalized()
	return Transform3D(Basis.looking_at(axis, edge), to_model * fist.point)
