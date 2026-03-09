-- ide_api_stubs.lua
-- Compact Luanti/Minetest API reference for LLM context injection.
--
-- Used by ide_system_prompts.lua / ide_gui.lua to optionally inject
-- API signatures into the CODE_GENERATOR system prompt.
--
-- Two levels:
--   slim  – ~30 most-used functions, minimal token cost (~400 tokens)
--   full  – comprehensive reference covering all major API areas (~2000 tokens)
--
-- Both levels are plain text, intentionally terse (signatures + 1-line notes).
-- No prose, no examples – LLMs already know Luanti; this is a precision anchor.
--
-- Token estimates assume ~4 chars/token average.

local stubs = {}

-- ============================================================
-- SLIM – everyday functions only
-- ============================================================

stubs.slim = [[
=== Luanti API – Core Reference (slim) ===
Runtime: LuaJIT (not standard Lua 5.1 – no string.split, no string.capitalize)
pos format: {x=number, y=number, z=number}

-- [ NODE ACCESS ] --
core.get_node(pos)                          → {name, param1, param2}
core.get_node_or_nil(pos)                   → {name, param1, param2} | nil
core.set_node(pos, {name=, param1=, param2=})
core.remove_node(pos)                       -- sets to "air"
core.find_node_near(pos, radius, nodenames) → pos | nil
core.find_nodes_in_area(minp, maxp, names)  → {pos,...}, {name: count}
core.get_meta(pos)                          → NodeMetaRef

-- [ REGISTRATION ] --
core.register_node("modname:name", def)
core.register_tool("modname:name", def)
core.register_craftitem("modname:name", def)
core.register_craft(def)                    -- {output=, recipe={{...}}}
core.register_entity("modname:name", def)
core.register_chatcommand("name", {privs={}, func=function(name, param) end})
core.register_on_player_receive_fields(function(player, formname, fields) end)
core.register_globalstep(function(dtime) end)
core.register_on_joinplayer(function(player) end)
core.register_on_leaveplayer(function(player) end)

-- [ PLAYER ] --
core.get_player_by_name(name)               → ObjectRef | nil
core.get_connected_players()                → {ObjectRef,...}
-- ObjectRef methods:
--   :get_pos()  :set_pos(pos)  :get_hp()  :set_hp(hp)
--   :get_inventory()  :get_wielded_item()  :get_player_name()
--   :set_look_horizontal(rad)  :set_look_vertical(rad)

-- [ CHAT & INTERACTION ] --
core.chat_send_player(name, msg)
core.chat_send_all(msg)
core.show_formspec(name, formname, formspec)
core.close_formspec(name, formname)

-- [ WORLD & TIMING ] --
core.after(delay_sec, func, ...)            → JobRef
core.get_gametime()                         → number (seconds since world start)
core.get_worldpath()                        → string
core.get_modpath(modname)                   → string | nil

-- [ ITEMS & INVENTORY ] --
ItemStack(itemstring)                       → ItemStack
-- InvRef:  :get_list(listname)  :set_list(listname, list)
--          :add_item(list, stack)  :remove_item(list, stack)

-- [ SOUNDS ] --
core.sound_play(spec, params)               → handle
core.sound_stop(handle)
-- Common sound presets (from default mod):
--   default.node_sound_stone_defaults()
--   default.node_sound_wood_defaults()
--   default.node_sound_dirt_defaults()
--   default.node_sound_sand_defaults()
--   default.node_sound_glass_defaults()
--   default.node_sound_leaves_defaults()

-- [ UTILITY ] --
core.serialize(val)                         → string
core.deserialize(str)                       → value
core.log(level, msg)                        -- level: "action","warning","error","verbose"
core.settings:get(key)                      → string | nil
core.settings:get_bool(key, default)        → bool
core.settings:set(key, val)
vector.new(x,y,z)  vector.add(a,b)  vector.subtract(a,b)
vector.length(v)   vector.normalize(v)  vector.distance(a,b)
=== END API (slim) ===
]]

-- ============================================================
-- FULL – comprehensive reference
-- ============================================================

stubs.full = [[
=== Luanti API – Core Reference (full) ===
⚠ Token cost: high. Disable when not needed.
Runtime: LuaJIT. pos = {x,y,z}. All coords are integers in most node ops.

-- [ NODE ACCESS & MANIPULATION ] --
core.get_node(pos)                              → {name, param1, param2}
core.get_node_or_nil(pos)                       → node | nil
core.set_node(pos, node)                        -- node = {name=, param1=0, param2=0}
core.add_node(pos, node)                        -- alias for set_node
core.remove_node(pos)                           -- sets "air"
core.swap_node(pos, node)                       -- keeps metadata
core.bulk_set_node({pos,...}, node)
core.get_node_light(pos, timeofday)             → 0–15 | nil
core.find_node_near(pos, radius, names, search_center) → pos | nil
core.find_nodes_in_area(minp, maxp, names)      → {pos,...}, {name:count}
core.find_nodes_in_area_under_air(minp, maxp, names) → {pos,...}
core.find_nodes_with_meta(minp, maxp)           → {pos,...}
core.get_node_max_level(pos)                    → number
core.get_node_level(pos)                        → number

-- [ METADATA ] --
core.get_meta(pos)                              → NodeMetaRef
-- NodeMetaRef: :get_string(k) :set_string(k,v)
--              :get_int(k)    :set_int(k,v)
--              :get_float(k)  :set_float(k,v)
--              :get_inventory() :to_table() :from_table(t)
--              :contains(k)   :get(k)  :set(k,v)  :mark_as_private(k)

-- [ REGISTRATION ] --
core.register_node("mod:name", def)
-- def fields: description, tiles, groups, sounds, drawtype,
--             node_box, selection_box, collision_box,
--             paramtype, paramtype2, light_source,
--             on_construct, on_destruct, on_dig, on_place,
--             on_punch, on_receive_fields, on_timer,
--             can_dig, after_place_node, after_dig_node,
--             drop, floodable, liquidtype, liquid_alternative_flowing
core.register_tool("mod:name", def)
-- def fields: description, inventory_image, tool_capabilities,
--             on_use, on_secondary_use, on_drop
-- tool_capabilities: {maxlevel, groupcaps={group={maxlevel,uses,times={...}}}}
core.register_craftitem("mod:name", def)
-- def fields: description, inventory_image, stack_max,
--             on_use, on_secondary_use, on_drop, groups
core.register_craft(def)
-- def: {output="mod:item N", recipe={{"mod:a","mod:b"},{"","mod:c"}}}
-- def: {type="shapeless", output=..., recipe={...}}
-- def: {type="fuel", recipe="mod:item", burntime=N}
-- def: {type="cooking", output=..., recipe=..., cooktime=N}
core.register_entity("mod:name", def)
-- def fields: initial_properties, on_activate, on_step, on_punch,
--             on_rightclick, get_staticdata, on_death
core.register_abm({nodenames, neighbors, interval, chance, action=function(pos,node,a,b)end})
core.register_lbm({name, nodenames, run_at_every_load, action=function(pos,node)end})
core.register_chatcommand("name", {description, params, privs, func=function(name,param)end})
core.register_privilege("name", {description, give_to_singleplayer, give_to_admin})
core.register_on_player_receive_fields(function(player,formname,fields) end)
core.register_on_joinplayer(function(player, last_login) end)
core.register_on_leaveplayer(function(player, timed_out) end)
core.register_on_dieplayer(function(player, reason) end)
core.register_on_respawnplayer(function(player) end)
core.register_on_chat_message(function(name, message) end)  → bool (true=block)
core.register_on_punchnode(function(pos,node,puncher,pointed_thing) end)
core.register_on_placenode(function(pos,newnode,placer,oldnode,itemstack,pt) end)
core.register_on_dignode(function(pos,oldnode,digger) end)
core.register_globalstep(function(dtime) end)
core.register_on_generated(function(minp,maxp,blockseed) end)

-- [ OBJECTS & ENTITIES ] --
core.add_entity(pos, name, staticdata)          → ObjectRef | nil
core.add_item(pos, item)                        → ObjectRef | nil
core.get_objects_inside_radius(pos, radius)     → {ObjectRef,...}
core.get_objects_in_area(minp, maxp)            → {ObjectRef,...}
-- ObjectRef (all): :get_pos() :set_pos(pos) :get_velocity() :set_velocity(v)
--   :get_acceleration() :set_acceleration(a) :get_rotation() :set_rotation(r)
--   :punch(puncher,time,tool,dir) :get_hp() :set_hp(hp) :get_armor_groups()
--   :is_player() :get_luaentity() :remove()
-- ObjectRef (player only):
--   :get_player_name() :get_inventory() :get_wielded_item()
--   :set_wielded_item(item) :get_player_velocity() :add_player_velocity(v)
--   :get_look_horizontal() :get_look_vertical()
--   :set_look_horizontal(rad) :set_look_vertical(rad)
--   :hud_add(def) :hud_remove(id) :hud_change(id,stat,val)
--   :set_sky(def) :set_sun(def) :set_moon(def) :set_stars(def)
--   :set_physics_override(def)

-- [ PLAYER & INVENTORY ] --
core.get_player_by_name(name)                   → ObjectRef | nil
core.get_connected_players()                    → {ObjectRef,...}
core.get_player_privs(name)                     → {priv=true,...}
core.set_player_privs(name, privs)
core.player_exists(name)                        → bool
ItemStack(itemstring_or_table)
-- ItemStack: :get_name() :get_count() :get_wear() :get_meta()
--   :is_empty() :to_string() :to_table() :set_count(n) :set_name(n)
--   :add_wear(n) :get_free_space() :item_fits(item)
core.get_craft_result({method, width, items})   → {item, time}, decremented
core.get_all_craft_recipes(name)                → {{...},...} | nil

-- [ WORLD & MAP ] --
core.get_worldpath()                            → string
core.get_modpath(modname)                       → string | nil
core.get_modnames()                             → {string,...}
core.get_game_info()                            → {id, title, ...}
core.get_server_info()                          → {address, port, ...}
core.get_mapgen_setting(name)                   → string | nil
core.set_mapgen_setting(name, val, override)
core.emerge_area(minp, maxp, callback)
core.delete_area(minp, maxp)
core.load_area(minp, maxp)
core.forceload_block(pos, transient)            → bool
core.forceload_free_block(pos, transient)
core.get_spawn_level(x, z)                      → y | nil

-- [ LIGHTING & ENV ] --
core.get_timeofday()                            → 0..1
core.set_timeofday(val)
core.get_day_count()                            → number
core.get_gametime()                             → number

-- [ SOUNDS ] --
core.sound_play(spec, params, ephemeral)        → handle
-- spec: "name" or {name=, gain=, pitch=}
-- params: {pos=, object=, to_player=, loop=, gain=, pitch=, fade=}
core.sound_stop(handle)
core.sound_fade(handle, step, gain)
-- Standard sound defaults (from default mod):
--   default.node_sound_stone_defaults()
--   default.node_sound_wood_defaults()
--   default.node_sound_dirt_defaults()
--   default.node_sound_sand_defaults()
--   default.node_sound_gravel_defaults()
--   default.node_sound_glass_defaults()
--   default.node_sound_metal_defaults()
--   default.node_sound_leaves_defaults()
--   default.node_sound_water_defaults()

-- [ CHAT & FORMSPEC ] --
core.chat_send_player(name, msg)
core.chat_send_all(msg)
core.show_formspec(name, formname, formspec)
core.close_formspec(name, formname)
core.formspec_escape(str)                       → string
-- Formspec elements (common): size[], label[], button[], field[], textarea[],
--   image[], item_image[], checkbox[], dropdown[], list[], box[], bgcolor[],
--   style[], style_type[], tooltip[], formspec_version[]

-- [ TIMING & ASYNC ] --
core.after(delay, func, ...)                    → JobRef (:cancel())
core.get_us_time()                              → microseconds

-- [ SETTINGS ] --
core.settings:get(key)                          → string | nil
core.settings:get_bool(key, default)            → bool
core.settings:get_np_group(key)                 → NoiseParams | nil
core.settings:set(key, val)
core.settings:set_bool(key, val)
core.settings:save()

-- [ UTILITY ] --
core.serialize(val)                             → string
core.deserialize(str, safe)                     → value | nil
core.parse_json(str, nullvalue)                 → value | nil, err
core.write_json(val, styled)                    → string | nil, err
core.log(level, msg)                            -- "none","error","warning","action","info","verbose"
core.debug(...)                                 -- prints to log
core.safe_file_write(path, content)             → bool
core.get_version()                              → {project, string, hash}
core.is_singleplayer()                          → bool
core.colorize(color, msg)                       → string
core.get_color_escape_sequence(color)           → string
core.encode_base64(str)                         → string
core.decode_base64(str)                         → string | nil
core.compress(data, method, ...)                → string
core.decompress(data, method, ...)              → string

-- [ VECTOR LIBRARY ] --
vector.new(x,y,z)          vector.zero()       vector.copy(v)
vector.add(a, b)            vector.subtract(a, b)
vector.multiply(v, s)       vector.divide(v, s)
vector.length(v)            vector.normalize(v)
vector.distance(a, b)       vector.direction(a, b)
vector.dot(a, b)            vector.cross(a, b)
vector.round(v)             vector.floor(v)     vector.ceil(v)
vector.equals(a, b)         vector.to_string(v)
vector.rotate(v, rot)       vector.rotate_around_axis(v, axis, angle)
vector.apply(v, func)       -- applies func to each component

-- [ NODE GROUPS (common) ] --
-- cracky=1..3  crumbly=1..3  choppy=1..3  snappy=1..3
-- oddly_breakable_by_hand=1..3  dig_immediate=2..3
-- not_in_creative_inventory=1  attached_node=1  falling_node=1
-- disable_jump=1  no_push_back=1  liquid=1  water=1  lava=1
-- igniter=1  flammable=1  puts_out_fire=1

-- [ DRAWTYPE VALUES ] --
-- normal  airlike  allfaces  allfaces_optional  glasslike
-- glasslike_framed  glasslike_framed_optional  torchlike
-- signlike  plantlike  plantlike_rooted  firelike
-- fencelike  raillike  nodebox  mesh  liquid  flowingliquid

-- [ PARAMTYPE2 VALUES ] --
-- none  facedir  wallmounted  leveled  degrotate
-- meshoptions  color  colorfacedir  colorwallmounted

=== END API (full) ===
]]

return stubs
