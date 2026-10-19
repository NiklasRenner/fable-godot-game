## The game's UI look, Classic style: dark tooled-leather panels in a brass frame with corner
## studs, red buttons with gold rims, bevelled slots for icons, glossy bars, blue-black tooltips,
## parchment for NPC dialogue and a serif face for names and headers.
## Every texture is drawn here at startup (small 9-slice images), so the look stays diffable and
## needs no art files; apply with `control.theme = UITheme.make()`.
class_name UITheme

const BG := Color(0.085, 0.07, 0.055, 0.94)
const BG_LIGHT := Color(0.17, 0.14, 0.11, 1.0)
const BG_DARK := Color(0.05, 0.04, 0.035, 1.0)
const BRASS := Color(0.72, 0.56, 0.26)
const BRASS_DIM := Color(0.38, 0.3, 0.16)
const GOLD_TEXT := Color(1.0, 0.82, 0.0)  # WoW's header gold
const TEXT := Color(0.92, 0.88, 0.8)
const TEXT_DIM := Color(0.6, 0.57, 0.5)
const INK := Color(0.2, 0.12, 0.05)       # text on parchment
const INK_TITLE := Color(0.32, 0.1, 0.02)
const ELITE := Color(1.0, 0.78, 0.25)

## Serif faces from the OS (no font files to ship): Palatino/Book Antiqua/Georgia on Windows,
## whatever serif exists elsewhere. Body text stays on Godot's clean sans for legibility.
const SERIF_NAMES := ["Palatino Linotype", "Book Antiqua", "Palatino", "Georgia", "Liberation Serif", "DejaVu Serif", "serif"]

static var _cached: Theme = null
static var _serif := {}
static var _tex := {}


static func serif(weight := 600) -> Font:
	if not _serif.has(weight):
		var f := SystemFont.new()
		f.font_names = PackedStringArray(SERIF_NAMES)
		f.font_weight = weight
		_serif[weight] = f
	return _serif[weight]


# ---------------------------------------------------------------- drawn textures

static func _img(w: int, h: int) -> Image:
	return Image.create(w, h, false, Image.FORMAT_RGBA8)


static func _texture(key: String, img: Image) -> ImageTexture:
	if not _tex.has(key):
		_tex[key] = ImageTexture.create_from_image(img)
	return _tex[key]


## Distance (in pixels) from the image edge, for drawing nested borders.
static func _edge(x: int, y: int, w: int, h: int) -> int:
	return mini(mini(x, y), mini(w - 1 - x, h - 1 - y))


## Brass trim, `n` pixels wide, lit from the top-left: bright outer lip, mid band, dark inner lip.
static func _brass(i: int, n: int, x: int, y: int, w: int, h: int, base := BRASS) -> Color:
	var c := base.lightened(0.35) if i == 0 else (base.darkened(0.45) if i == n - 1 else base)
	var lit := (x < w / 2 and y < h / 2)
	return c.lightened(0.1) if lit else c.darkened(0.1)


## Leather panel: black hairline, 3 px brass, black hairline, then leather with a faint grain and
## an inner shadow; brass studs in the corners.
static func _panel_image(trim: Color) -> Image:
	var w := 48
	var img := _img(w, w)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for y in w:
		for x in w:
			var e := _edge(x, y, w, w)
			var c: Color
			if e == 0 or e == 4:
				c = Color(0.02, 0.015, 0.01)
			elif e <= 3:
				c = _brass(e - 1, 3, x, y, w, w, trim)
			else:
				var grain := rng.randf_range(-0.012, 0.012) + 0.008 * sin(y * 1.7 + sin(x * 0.4) * 2.0)
				c = Color(BG.r + grain, BG.g + grain * 0.8, BG.b + grain * 0.6, BG.a)
				c = c.darkened(clampf(0.35 - 0.06 * (e - 5), 0.0, 0.35))  # inner shadow
			img.set_pixel(x, y, c)
	for corner in [Vector2(7, 7), Vector2(w - 8, 7), Vector2(7, w - 8), Vector2(w - 8, w - 8)]:
		for y in range(-3, 4):
			for x in range(-3, 4):
				var d := Vector2(x, y).length()
				if d <= 2.6:
					var c := trim.lightened(0.45 - 0.12 * (x + y) / 3.0) if d < 1.6 else trim.darkened(0.35)
					img.set_pixel(int(corner.x) + x, int(corner.y) + y, c)
	return img


static func _panel_style(trim := BRASS, margin := 12) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	sb.texture = _texture("panel_%s" % trim.to_html(), _panel_image(trim))
	sb.set_texture_margin_all(12)
	sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
	sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
	sb.content_margin_left = margin
	sb.content_margin_right = margin
	sb.content_margin_top = margin * 0.85
	sb.content_margin_bottom = margin * 0.85
	return sb


## Red button with a gold rim (the Classic panel button), in four states.
static func _button_image(state: String) -> Image:
	var w := 32
	var h := 24
	var img := _img(w, h)
	var top := Color(0.62, 0.1, 0.06)
	var bottom := Color(0.32, 0.03, 0.02)
	var rim := Color(0.85, 0.66, 0.22)
	match state:
		"hover":
			top = top.lightened(0.18)
			bottom = bottom.lightened(0.12)
			rim = rim.lightened(0.25)
		"pressed":
			var t := top
			top = bottom.darkened(0.2)
			bottom = t.darkened(0.25)
		"disabled":
			top = Color(0.3, 0.28, 0.26)
			bottom = Color(0.16, 0.15, 0.14)
			rim = Color(0.45, 0.42, 0.38)
	for y in h:
		for x in w:
			var e := _edge(x, y, w, h)
			var c: Color
			if e == 0:
				c = Color(0.03, 0.02, 0.01)
			elif e == 1:
				c = rim if y < h / 2 else rim.darkened(0.3)
			else:
				c = top.lerp(bottom, float(y - 2) / float(h - 5))
				if y == 2:
					c = c.lightened(0.25)  # glossy top edge
			img.set_pixel(x, y, c)
	return img


static func _button_style(state: String) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	sb.texture = _texture("button_" + state, _button_image(state))
	sb.set_texture_margin_all(4)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 5
	sb.content_margin_bottom = 6
	return sb


## An icon slot: black hairline, a bevelled steel-brass rim, black inside.
static func _slot_image(rim: Color) -> Image:
	var w := 40
	var img := _img(w, w)
	for y in w:
		for x in w:
			var e := _edge(x, y, w, w)
			var c := Color(0.02, 0.02, 0.02)
			if e >= 1 and e <= 3:
				var lit := x + y < w  # top-left lit, bottom-right in shade
				c = rim.lightened(0.3 - 0.12 * (e - 1)) if lit else rim.darkened(0.35 + 0.1 * (e - 1))
			elif e > 4:
				c = Color(0.04, 0.035, 0.03, 0.9)
			img.set_pixel(x, y, c)
	return img


static func slot_style(rim := Color(0.55, 0.5, 0.42), pad := 4) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	sb.texture = _texture("slot_%s" % rim.to_html(), _slot_image(rim))
	sb.set_texture_margin_all(6)
	sb.set_content_margin_all(pad)
	return sb


## A glossy bar fill: white, shaded top to bottom; tinted per bar with modulate_color.
static func _bar_image() -> Image:
	var h := 16
	var img := _img(4, h)
	for y in h:
		var v := 1.0 - 0.45 * float(y) / float(h - 1)
		if y == 1:
			v = 1.25
		elif y < 5:
			v += 0.1
		for x in 4:
			img.set_pixel(x, y, Color(v, v, v, 1.0))
	return img


## Parchment for NPC dialogue: warm paper with mottling, a darker edge and a thin brown rule.
static func _parchment_image() -> Image:
	var w := 64
	var img := _img(w, w)
	var noise := FastNoiseLite.new()
	noise.frequency = 0.08
	noise.seed = 3
	for y in w:
		for x in w:
			var e := _edge(x, y, w, w)
			var n := noise.get_noise_2d(x, y) * 0.06
			var c := Color(0.86 + n, 0.76 + n, 0.56 + n * 0.8)
			c = c.darkened(clampf(0.3 - 0.03 * e, 0.0, 0.3))
			if e == 0:
				c = Color(0.18, 0.1, 0.04)
			elif e == 3:
				c = c.darkened(0.35)
			img.set_pixel(x, y, c)
	return img


static func parchment_style() -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	sb.texture = _texture("parchment", _parchment_image())
	sb.set_texture_margin_all(10)
	sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
	sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 16
	sb.content_margin_bottom = 16
	return sb


# ---------------------------------------------------------------- theme

## Flat styles (kept for one-off highlights, e.g. the selected class on character creation).
static func panel_box(bg := BG, border := BRASS, radius := 4, border_w := 2, margin := 10) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(border_w)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = margin
	sb.content_margin_right = margin
	sb.content_margin_top = margin * 0.8
	sb.content_margin_bottom = margin * 0.8
	return sb


static func button_box(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	return sb


## The frame around a unit frame, cast bar or other small HUD piece; `elite` is the gold one.
static func frame_style(elite := false) -> StyleBoxTexture:
	return _panel_style(ELITE if elite else BRASS, 10)


static func make() -> Theme:
	if _cached:
		return _cached
	var t := Theme.new()
	t.default_font_size = 13

	t.set_stylebox("panel", "PanelContainer", _panel_style())
	# WoW's tooltip: translucent blue-black with a silver hairline
	var tip := panel_box(Color(0.02, 0.02, 0.07, 0.94), Color(0.62, 0.62, 0.68), 3, 1, 9)
	t.set_stylebox("panel", "TooltipPanel", tip)
	t.set_color("font_color", "TooltipLabel", TEXT)
	t.set_font_size("font_size", "TooltipLabel", 12)

	for state in ["normal", "hover", "pressed", "disabled"]:
		t.set_stylebox(state, "Button", _button_style(state))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_font("font", "Button", serif(600))
	t.set_color("font_color", "Button", GOLD_TEXT)
	t.set_color("font_hover_color", "Button", Color(1, 0.92, 0.55))
	t.set_color("font_pressed_color", "Button", GOLD_TEXT.darkened(0.15))
	t.set_color("font_disabled_color", "Button", TEXT_DIM)
	t.set_color("font_outline_color", "Button", Color(0, 0, 0, 0.8))
	t.set_constant("outline_size", "Button", 2)

	t.set_color("font_color", "Label", TEXT)
	t.set_color("default_color", "RichTextLabel", TEXT)

	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(0.03, 0.03, 0.03, 0.85)
	bar_bg.border_color = Color(0.0, 0.0, 0.0)
	bar_bg.set_border_width_all(1)
	t.set_stylebox("background", "ProgressBar", bar_bg)

	var le := button_box(BG_DARK, BRASS_DIM)
	t.set_stylebox("normal", "LineEdit", le)
	t.set_stylebox("focus", "LineEdit", button_box(BG_DARK, BRASS))
	t.set_color("font_color", "LineEdit", TEXT)

	var sep := StyleBoxLine.new()
	sep.color = BRASS_DIM
	sep.thickness = 1
	t.set_stylebox("separator", "HSeparator", sep)

	_cached = t
	return t


## A gold serif header.
static func header(text: String, size := 15, color := GOLD_TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", serif(700))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	return l


## Glossy fill for a bar in `color`.
static func fill_box(color: Color) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	sb.texture = _texture("bar", _bar_image())
	sb.modulate_color = color
	sb.set_texture_margin_all(0)
	return sb


# ---------------------------------------------------------------- widget helpers

## A small text label.
static func small(text: String, size := 12, color := TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


## A button with a click sound that never steals keyboard focus (so Space/Enter keep moving you).
static func button(text: String, on_pressed: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(func() -> void: Audio.play("click"))
	b.pressed.connect(on_pressed)
	return b


## Place a control by anchor point + pixel offset from that anchor (resolution independent).
static func anchor(c: Control, preset: int, offset: Vector2, size: Vector2 = Vector2.ZERO) -> void:
	c.set_anchors_preset(preset)
	c.offset_left = offset.x
	c.offset_top = offset.y
	c.offset_right = offset.x + size.x
	c.offset_bottom = offset.y + size.y
	# The offset is the control's top-left corner; it grows right/down from there.
	c.grow_horizontal = Control.GROW_DIRECTION_END
	c.grow_vertical = Control.GROW_DIRECTION_END


## A progress bar with a centred "value / max" label.
static func bar(color: Color, height := 18) -> ProgressBar:
	var b := ProgressBar.new()
	b.custom_minimum_size = Vector2(0, height)
	b.show_percentage = false
	b.add_theme_stylebox_override("fill", fill_box(color))
	var lbl := Label.new()
	lbl.name = "Value"
	lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color(1, 1, 1))
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	lbl.add_theme_constant_override("outline_size", 3)
	b.add_child(lbl)
	return b


static func set_bar(b: ProgressBar, value: int, max_value: int) -> void:
	b.max_value = maxi(1, max_value)
	b.value = value
	b.get_node("Value").text = "%d / %d" % [value, max_value]


## A round level badge (unit frames): the number in `color` on a dark disc in a brass ring.
static func level_badge() -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.04, 0.03)
	sb.border_color = BRASS
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(18)
	sb.shadow_color = Color(0, 0, 0, 0.6)
	sb.shadow_size = 3
	p.add_theme_stylebox_override("panel", sb)
	p.custom_minimum_size = Vector2(34, 34)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var l := header("", 15)
	l.name = "Level"
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	p.add_child(l)
	return p


## WoW's level colours: how dangerous `level` is for someone of `own` level.
static func difficulty_color(level: int, own: int) -> Color:
	var d := level - own
	if d >= 5:
		return Color(1.0, 0.1, 0.1)
	if d >= 3:
		return Color(1.0, 0.5, 0.25)
	if d >= -2:
		return Color(1.0, 0.82, 0.0)
	if d >= -5:
		return Color(0.25, 0.75, 0.25)
	return Color(0.62, 0.62, 0.62)


## Labels an item button: name in its quality colour and a tooltip, or `empty_text` dimmed.
static func item_button(b: Button, id: String, empty_text: String) -> void:
	if id == "":
		b.text = empty_text
		b.tooltip_text = ""
		b.add_theme_color_override("font_color", TEXT_DIM)
		return
	var it := GameData.item(id)
	b.text = it.get("name", id)
	b.tooltip_text = GameData.item_tooltip(id) + "\nSell: " + GameData.format_copper(it.get("sell", 0))
	b.add_theme_color_override("font_color", GameData.QUALITY_COLORS.get(it.get("quality", "common"), Color.WHITE))
