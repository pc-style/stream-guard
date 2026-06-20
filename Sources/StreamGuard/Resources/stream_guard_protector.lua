-- Stream Guard OBS Protector
--
-- Load in OBS: Tools -> Scripts -> + -> stream_guard_protector.lua
--
-- This creates a protected scene:
--   1. Your selected live source is inserted with a Render Delay filter.
--   2. A full-screen STREAM_GUARD_BLACKOUT color source sits above it.
--   3. Stream Guard toggles that blackout source through obs-websocket.
--
-- Keep Stream Guard watching the live/undelayed screen. Stream/record the
-- generated protected scene so the blackout can arrive before delayed leak
-- frames reach viewers.

obs = obslua

local protected_scene_name = "STREAM_GUARD_PROTECTED"
local blackout_source_name = "STREAM_GUARD_BLACKOUT"
local live_source_name = ""
local delay_ms = 3000
local blackout_enabled_after_setup = false

local function release(source)
    if source ~= nil then
        obs.obs_source_release(source)
    end
end

local function scene_source_by_name(name)
    return obs.obs_get_source_by_name(name)
end

local function ensure_scene_object(name)
    local existing = scene_source_by_name(name)
    if existing ~= nil then
        local scene = obs.obs_scene_from_source(existing)
        release(existing)
        return scene
    end
    return obs.obs_scene_create(name)
end

local function canvas_dimensions()
    local video_info = obs.obs_video_info()
    if obs.obs_get_video_info(video_info) then
        return video_info.base_width, video_info.base_height
    end
    return 1920, 1080
end

local function blackout_settings_for_canvas()
    local width, height = canvas_dimensions()
    local settings = obs.obs_data_create()
    obs.obs_data_set_int(settings, "color", 0xFF000000)
    obs.obs_data_set_int(settings, "width", width)
    obs.obs_data_set_int(settings, "height", height)
    return settings
end

local function ensure_blackout_source()
    local settings = blackout_settings_for_canvas()
    local existing = scene_source_by_name(blackout_source_name)
    if existing ~= nil then
        obs.obs_source_update(existing, settings)
        obs.obs_data_release(settings)
        return existing
    end

    local source = obs.obs_source_create("color_source", blackout_source_name, settings, nil)
    obs.obs_data_release(settings)
    return source
end

local function add_render_delay_filter(source)
    if source == nil then
        return
    end

    local existing = obs.obs_source_get_filter_by_name(source, "Stream Guard Delay")
    if existing ~= nil then
        local settings = obs.obs_source_get_settings(existing)
        obs.obs_data_set_int(settings, "delay_ms", delay_ms)
        obs.obs_source_update(existing, settings)
        obs.obs_data_release(settings)
        release(existing)
        return
    end

    local settings = obs.obs_data_create()
    obs.obs_data_set_int(settings, "delay_ms", delay_ms)
    local filter = obs.obs_source_create_private("gpu_delay", "Stream Guard Delay", settings)
    obs.obs_data_release(settings)
    if filter ~= nil then
        obs.obs_source_filter_add(source, filter)
        release(filter)
    end
end

local function add_or_reuse_scene_item(scene, source)
    if scene == nil or source == nil then
        return nil
    end

    local item = obs.obs_scene_find_source(scene, obs.obs_source_get_name(source))
    if item ~= nil then
        return item
    end
    return obs.obs_scene_add(scene, source)
end

local function fit_item_to_canvas(item)
    if item == nil then
        return
    end

    local video_info = obs.obs_video_info()
    if not obs.obs_get_video_info(video_info) then
        return
    end

    local bounds = obs.vec2()
    bounds.x = video_info.base_width
    bounds.y = video_info.base_height
    obs.obs_sceneitem_set_bounds_type(item, obs.OBS_BOUNDS_STRETCH)
    obs.obs_sceneitem_set_bounds(item, bounds)

    local pos = obs.vec2()
    pos.x = 0
    pos.y = 0
    obs.obs_sceneitem_set_pos(item, pos)
end

local function setup_protected_scene()
    if live_source_name == nil or live_source_name == "" then
        obs.script_log(obs.LOG_WARNING, "Choose a live source before setup.")
        return
    end

    local protected_scene = ensure_scene_object(protected_scene_name)
    local live_source = scene_source_by_name(live_source_name)
    local blackout_source = ensure_blackout_source()

    if protected_scene == nil then
        obs.script_log(obs.LOG_WARNING, "Could not create protected scene: " .. protected_scene_name)
        release(live_source)
        release(blackout_source)
        return
    end

    if live_source == nil then
        obs.script_log(obs.LOG_WARNING, "Live source not found: " .. live_source_name)
        release(blackout_source)
        return
    end

    add_render_delay_filter(live_source)

    local live_item = add_or_reuse_scene_item(protected_scene, live_source)
    local blackout_item = add_or_reuse_scene_item(protected_scene, blackout_source)

    fit_item_to_canvas(live_item)
    fit_item_to_canvas(blackout_item)
    if blackout_item ~= nil then
        obs.obs_sceneitem_set_visible(blackout_item, blackout_enabled_after_setup)
    end

    obs.script_log(
        obs.LOG_INFO,
        "Stream Guard protected scene ready. Stream scene: " .. protected_scene_name ..
            ", blackout source: " .. blackout_source_name ..
            ", delay: " .. tostring(delay_ms) .. " ms."
    )

    release(live_source)
    release(blackout_source)
end

local function source_name_list()
    local sources = obs.obs_enum_sources()
    local list = {}
    if sources ~= nil then
        for _, source in ipairs(sources) do
            local name = obs.obs_source_get_name(source)
            if name ~= protected_scene_name and name ~= blackout_source_name then
                table.insert(list, name)
            end
        end
        obs.source_list_release(sources)
    end
    table.sort(list)
    return list
end

function script_description()
    return "Creates a delayed Stream Guard protected scene with a WebSocket-toggleable blackout source."
end

function script_properties()
    local props = obs.obs_properties_create()

    local source_prop = obs.obs_properties_add_list(
        props,
        "live_source_name",
        "Live source to delay",
        obs.OBS_COMBO_TYPE_LIST,
        obs.OBS_COMBO_FORMAT_STRING
    )
    for _, name in ipairs(source_name_list()) do
        obs.obs_property_list_add_string(source_prop, name, name)
    end

    obs.obs_properties_add_int(props, "delay_ms", "Protected scene delay (ms)", 500, 120000, 100)
    obs.obs_properties_add_bool(props, "blackout_enabled_after_setup", "Leave blackout visible after setup")
    obs.obs_properties_add_button(props, "setup", "Create / update protected scene", setup_protected_scene)

    return props
end

function script_update(settings)
    live_source_name = obs.obs_data_get_string(settings, "live_source_name")
    delay_ms = obs.obs_data_get_int(settings, "delay_ms")
    blackout_enabled_after_setup = obs.obs_data_get_bool(settings, "blackout_enabled_after_setup")
end

function script_defaults(settings)
    obs.obs_data_set_default_int(settings, "delay_ms", 3000)
    obs.obs_data_set_default_bool(settings, "blackout_enabled_after_setup", false)
end
