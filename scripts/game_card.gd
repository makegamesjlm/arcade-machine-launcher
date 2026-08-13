class_name GameCard
extends PanelContainer
## One tile in the game grid: icon, title, player count.
##
## Selection is driven entirely by Main rather than by Godot's focus system.
## The cabinet has no mouse and no tab key, so a single explicit "which index is
## selected" is easier to reason about than focus neighbours.

const SELECTED_SCALE := 1.05
const TRANSITION_SECONDS := 0.12

@export var normal_style: StyleBoxFlat
@export var selected_style: StyleBoxFlat

var game: GameEntry

var _selected := false
var _tween: Tween

@onready var _icon: TextureRect = %Icon
@onready var _placeholder: Label = %Placeholder
@onready var _title: Label = %Title
@onready var _players: Label = %Players
@onready var _held_badge: PanelContainer = %HeldBadge


func _ready() -> void:
	resized.connect(func() -> void: pivot_offset = size * 0.5)


func setup(entry: GameEntry) -> void:
	game = entry
	_title.text = entry.name
	_players.text = entry.players_label()

	var image := Image.load_from_file(entry.icon_path) if not entry.icon_path.is_empty() else null
	if image == null:
		_show_placeholder(entry)
	else:
		_icon.texture = ImageTexture.create_from_image(image)
		_placeholder.hide()


## Games without an icon.png get a tinted initial instead of an empty hole. The
## hue is derived from the folder name so a given game always looks the same.
func _show_placeholder(entry: GameEntry) -> void:
	_icon.hide()
	_placeholder.text = entry.name.substr(0, 1).to_upper()

	var background := StyleBoxFlat.new()
	background.bg_color = Color.from_hsv(wrapf(float(entry.id.hash()) / 4096.0, 0.0, 1.0), 0.45, 0.34)
	background.set_corner_radius_all(10)
	_placeholder.add_theme_stylebox_override("normal", background)


## Shows or hides the "HELD" badge - the grid's cue that selecting this game
## resumes it where it was left rather than restarting it. main.gd is the
## only caller, and only ever has one card held at a time.
func set_held(value: bool) -> void:
	_held_badge.visible = value


func set_selected(value: bool) -> void:
	if _selected == value:
		return
	_selected = value

	add_theme_stylebox_override("panel", selected_style if value else normal_style)
	# Lift the selected card so its grown edges sit above its neighbours.
	z_index = 1 if value else 0

	if _tween != null and _tween.is_running():
		_tween.kill()
	_tween = create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_tween.tween_property(self, "scale",
		Vector2.ONE * (SELECTED_SCALE if value else 1.0), TRANSITION_SECONDS)


## Plays when the card is chosen, so the press has a visible acknowledgement
## before the screen fades out.
func play_press() -> void:
	if _tween != null and _tween.is_running():
		_tween.kill()
	_tween = create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	_tween.tween_property(self, "scale", Vector2.ONE * 0.94, 0.06)
	_tween.tween_property(self, "scale", Vector2.ONE * SELECTED_SCALE, 0.14)
