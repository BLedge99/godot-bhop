extends CanvasLayer

const SETTINGS_PATH := "user://settings.cfg"
const BINDINGS := {
	"Forward": "forward_key", "Back": "back_key", "Left": "left_key",
	"Right": "right_key", "Jump": "jump_key"
}

var player: Node
var panel: PanelContainer
var sensitivity_value: Label
var yaw_value: Label
var binding_buttons: Dictionary = {}
var waiting_for: String = ""
var mode_button: Button
var shade: ColorRect
var center: CenterContainer

func _ready() -> void:
	add_to_group(&"settings_menu")
	player = get_tree().get_first_node_in_group(&"player")
	_build_ui()
	_load_settings()
	panel.visible = false
	shade.visible = false
	center.visible = false

func _build_ui() -> void:
	shade = ColorRect.new()
	shade.color = Color(0, 0, 0, 0.58)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	center = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(440, 0)
	center.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	panel.add_child(column)
	var title := Label.new()
	title.text = "Settings"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	column.add_child(title)
	var mode_row := HBoxContainer.new()
	column.add_child(mode_row)
	var mode_label := Label.new()
	mode_label.text = "Jump mode"
	mode_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mode_row.add_child(mode_label)
	mode_button = Button.new()
	mode_button.pressed.connect(_cycle_mode)
	mode_row.add_child(mode_button)
	_add_slider(column, "Mouse sensitivity", 0.01, 10.0, 0.01, "sensitivity")
	_add_slider(column, "m_yaw", 0.001, 0.1, 0.001, "yaw")
	var separator := HSeparator.new()
	column.add_child(separator)
	var heading := Label.new()
	heading.text = "Movement keys (click a key, then press a replacement)"
	column.add_child(heading)
	for label in BINDINGS:
		var row := HBoxContainer.new()
		column.add_child(row)
		var name := Label.new()
		name.text = label
		name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name)
		var button := Button.new()
		button.custom_minimum_size.x = 110
		button.pressed.connect(_begin_rebind.bind(label))
		row.add_child(button)
		binding_buttons[label] = button
	var close := Button.new()
	close.text = "Resume (Esc)"
	close.pressed.connect(close_menu)
	column.add_child(close)
	_refresh_labels()

func _add_slider(parent: VBoxContainer, title: String, low: float, high: float, step: float, kind: String) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = title
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var value := Label.new()
	value.custom_minimum_size.x = 52
	row.add_child(value)
	var slider := HSlider.new()
	slider.min_value = low
	slider.max_value = high
	slider.step = step
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)
	if kind == "sensitivity":
		sensitivity_value = value
		slider.value_changed.connect(_set_sensitivity)
	else:
		yaw_value = value
		slider.value_changed.connect(_set_yaw)
	slider.set_meta("kind", kind)
	if kind == "sensitivity":
		slider.value = player.mouse_sensitivity
	else:
		slider.value = player.m_yaw

func _refresh_labels() -> void:
	if player == null:
		return
	if sensitivity_value != null:
		sensitivity_value.text = "%.2f" % player.mouse_sensitivity
	if yaw_value != null:
		yaw_value.text = "%.3f" % player.m_yaw
	if mode_button != null:
		mode_button.text = "Auto bhop" if player.jump_mode == "auto" else "Scroll"
	for label in BINDINGS:
		if binding_buttons.has(label):
			var key: Key = player.get(BINDINGS[label])
			binding_buttons[label].text = OS.get_keycode_string(key)

func _set_sensitivity(value: float) -> void:
	player.mouse_sensitivity = value
	_refresh_labels()
	_save_settings()

func _set_yaw(value: float) -> void:
	player.m_yaw = value
	_refresh_labels()
	_save_settings()

func _cycle_mode() -> void:
	player.jump_mode = "scroll" if player.jump_mode == "auto" else "auto"
	_refresh_labels()
	_save_settings()

func _begin_rebind(action: String) -> void:
	waiting_for = action
	binding_buttons[action].text = "Press a key…"
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _input(event: InputEvent) -> void:
	if not panel.visible:
		return
	if waiting_for != "" and event is InputEventKey and event.pressed and not event.echo:
		if event.keycode != KEY_ESCAPE:
			player.set(BINDINGS[waiting_for], event.physical_keycode if event.physical_keycode != 0 else event.keycode)
		waiting_for = ""
		_refresh_labels()
		_save_settings()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close_menu()
		get_viewport().set_input_as_handled()

func toggle() -> void:
	if panel.visible:
		close_menu()
	else:
		panel.visible = true
		shade.visible = true
		center.visible = true
		waiting_for = ""
		_refresh_labels()
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func close_menu() -> void:
	waiting_for = ""
	panel.visible = false
	shade.visible = false
	center.visible = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("mouse", "sensitivity", player.mouse_sensitivity)
	cfg.set_value("mouse", "m_yaw", player.m_yaw)
	cfg.set_value("movement", "jump_mode", player.jump_mode)
	for label in BINDINGS:
		cfg.set_value("keys", BINDINGS[label], int(player.get(BINDINGS[label])))
	cfg.save(SETTINGS_PATH)

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	player.mouse_sensitivity = float(cfg.get_value("mouse", "sensitivity", player.mouse_sensitivity))
	player.m_yaw = float(cfg.get_value("mouse", "m_yaw", player.m_yaw))
	player.jump_mode = str(cfg.get_value("movement", "jump_mode", player.jump_mode))
	for label in BINDINGS:
		var key_code := int(cfg.get_value("keys", BINDINGS[label], int(player.get(BINDINGS[label]))))
		player.set(BINDINGS[label], key_code)
	_refresh_sliders()
	_refresh_labels()

func _refresh_sliders() -> void:
	for child in panel.find_children("HSlider", "HSlider", true, false):
		if child.get_meta("kind", "") == "sensitivity":
			child.set_value_no_signal(player.mouse_sensitivity)
		else:
			child.set_value_no_signal(player.m_yaw)
