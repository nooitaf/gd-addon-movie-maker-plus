@tool
extends EditorPlugin

# Grouping settings back under Godot's Movie Writer category but with a nested path for grouping
const SETTING_OUT_DIR = "editor/movie_writer/movie_maker_plus/output_folder"
const SETTING_BASE_NAME = "editor/movie_writer/movie_maker_plus/file_base_name"
const SETTING_FORMAT = "editor/movie_writer/movie_maker_plus/output_format"

const SETTING_AUTO_CONVERT = "editor/movie_writer/movie_maker_plus/auto_convert_to_mp4"
const SETTING_FFMPEG_PATH = "editor/movie_writer/movie_maker_plus/ffmpeg_path"

# The original Godot setting we are injecting into
const SETTING_ACTUAL_FILE = "editor/movie_writer/movie_file"

var _was_playing = false
var _recording_was_active = false
var _locked_recorded_path = ""
var _poll_timer = Timer.new()

var _last_checked_ffmpeg_path = ""

func _enter_tree():
	# Get project name for a sensible default base name
	var project_name = ProjectSettings.get_setting("application/config/name", "")
	if project_name == "":
		project_name = "movie"
	else:
		project_name = project_name.validate_filename().to_snake_case()

	# Default output folder to project root if not set
	var default_dir = ProjectSettings.globalize_path("res://")

	# 1. Initialize settings. The extra / in the path naturally creates a sub-group in Godot 4.
	# We set the order explicitly to ensure the specified layout
	var base_order = ProjectSettings.get_order(SETTING_ACTUAL_FILE)
	
	_setup_setting(SETTING_OUT_DIR, default_dir, TYPE_STRING, base_order + 10, PROPERTY_HINT_GLOBAL_DIR)
	_setup_setting(SETTING_BASE_NAME, project_name, TYPE_STRING, base_order + 11)
	_setup_setting(SETTING_FORMAT, "avi", TYPE_STRING, base_order + 12, PROPERTY_HINT_ENUM, "avi,png,ogv")
	_setup_setting(SETTING_AUTO_CONVERT, false, TYPE_BOOL, base_order + 13)
	_setup_setting(SETTING_FFMPEG_PATH, "ffmpeg", TYPE_STRING, base_order + 14)

	# 2. Hide internal Godot setting to avoid confusion
	ProjectSettings.set_as_internal(SETTING_ACTUAL_FILE, true)

	# 3. Initial Update
	_update_movie_file_path()
	_check_ffmpeg_installation()

	# 4. Connect signals and Polling
	ProjectSettings.settings_changed.connect(_on_settings_changed)

	add_child(_poll_timer)
	_poll_timer.timeout.connect(_on_poll_tick)
	_poll_timer.start(1.0)

func _on_settings_changed():
	_update_movie_file_path()
	_check_ffmpeg_installation()

func _check_ffmpeg_installation():
	if not ProjectSettings.get_setting(SETTING_AUTO_CONVERT, false):
		return

	var ffmpeg = ProjectSettings.get_setting(SETTING_FFMPEG_PATH, "ffmpeg")
	if ffmpeg == _last_checked_ffmpeg_path:
		return

	_last_checked_ffmpeg_path = ffmpeg
	var output = []
	var exit_code = OS.execute(ffmpeg, ["-version"], output)

	if exit_code == 0:
		print("[Movie Maker Plus] FFmpeg check: OK (Version found)")
	else:
		printerr("[Movie Maker Plus] FFmpeg check: FAILED. Could not find FFmpeg at '", ffmpeg, "'. Auto-conversion will fail.")

func _setup_setting(name: String, default: Variant, type: int, order: int, hint: int = PROPERTY_HINT_NONE, hint_str: String = ""):
	# Ensure the setting exists before we add property info
	if not ProjectSettings.has_setting(name):
		ProjectSettings.set_setting(name, default)
	
	ProjectSettings.set_initial_value(name, default)
	ProjectSettings.set_order(name, order)
	
	var info = {
		"name": name,
		"type": type,
		"hint": hint,
		"hint_string": hint_str
	}
	# usage is NOT supported in add_property_info for ProjectSettings in recent Godot 4 versions
	ProjectSettings.add_property_info(info)
	
	# Mark as basic so it shows without "Advanced Settings" enabled
	ProjectSettings.set_as_basic(name, true)

func _notification(what):
	if what == NOTIFICATION_WM_WINDOW_FOCUS_IN:
		_update_movie_file_path()

func _on_poll_tick():
	var ei = get_editor_interface()
	
	# Safety check for movie maker mode
	var movie_maker_on = false
	if ei.has_method("is_movie_maker_enabled"):
		movie_maker_on = ei.is_movie_maker_enabled()
	
	var is_playing = false
	if ei.has_method("is_playing"):
		is_playing = ei.is_playing()
	else:
		is_playing = ei.get_playing_scene() != ""
	
	# Detect when the game STARTS
	if is_playing and not _was_playing:
		if movie_maker_on:
			_recording_was_active = true
			_locked_recorded_path = ProjectSettings.get_setting(SETTING_ACTUAL_FILE)
			print("[Movie Maker Plus] Game started. Movie Maker active. Locked path: ", _locked_recorded_path)
		else:
			_recording_was_active = false
		
	# Detect when the game STOPS
	if not is_playing and _was_playing:
		if _recording_was_active:
			print("[Movie Maker Plus] Game stopped. Checking for conversion...")
			_check_for_conversion()
		
	_was_playing = is_playing
	
	# Keep the timestamp fresh while in editor (if Movie Maker is ON)
	if not is_playing and movie_maker_on:
		_update_movie_file_path()

func _update_movie_file_path():
	var ei = get_editor_interface()
	if ei.has_method("is_movie_maker_enabled"):
		if not ei.is_movie_maker_enabled():
			return

	var dir = ProjectSettings.get_setting(SETTING_OUT_DIR, "")
	var base = ProjectSettings.get_setting(SETTING_BASE_NAME, "movie")
	var ext = ProjectSettings.get_setting(SETTING_FORMAT, "avi")
	
	if dir == "": return

	var timestamp = Time.get_datetime_string_from_system().replace(":", ".").replace("T", "_")
	
	if not dir.ends_with("/") and not dir.ends_with("\\"):
		dir += "/"
		
	var final_path = dir + base + "-" + timestamp + "." + ext
	
	if ProjectSettings.get_setting(SETTING_ACTUAL_FILE) != final_path:
		ProjectSettings.set_setting(SETTING_ACTUAL_FILE, final_path)

func _check_for_conversion():
	if not ProjectSettings.get_setting(SETTING_AUTO_CONVERT, false):
		return
		
	if _locked_recorded_path == "":
		return

	var global_path = ProjectSettings.globalize_path(_locked_recorded_path)
	if not FileAccess.file_exists(global_path):
		print("[Movie Maker Plus] Source file not found: ", global_path)
		return
		
	var ffmpeg = ProjectSettings.get_setting(SETTING_FFMPEG_PATH, "ffmpeg")
	var output_mp4 = _locked_recorded_path.get_basename() + ".mp4"
	var global_output = ProjectSettings.globalize_path(output_mp4)
	
	var args = [
		"-i", global_path,
		"-c:v", "libx264",
		"-crf", "18",
		"-pix_fmt", "yuv420p",
		"-y",
		global_output
	]
	
	print("[Movie Maker Plus] Running FFmpeg: ", ffmpeg, " ", " ".join(args))
	
	var pid = OS.create_process(ffmpeg, args)
	
	if pid == -1:
		printerr("[Movie Maker Plus] ERROR: Failed to start FFmpeg process.")
	else:
		print("[Movie Maker Plus] SUCCESS: Conversion started in background (PID: ", pid, ")")

func _exit_tree():
	if ProjectSettings.settings_changed.is_connected(_on_settings_changed):
		ProjectSettings.settings_changed.disconnect(_on_settings_changed)
	
	ProjectSettings.set_as_internal(SETTING_ACTUAL_FILE, false)
	if _poll_timer:
		_poll_timer.stop()
		_poll_timer.queue_free()
