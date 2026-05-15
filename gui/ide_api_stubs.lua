-- ===========================================================================
--  ide_api_stubs.lua — LLM Connect / Smart Lua IDE
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  Compact Luanti/Minetest API reference for LLM context injection.
--  Used by ide_system_prompts.lua to inject API signatures into
--  CODE_GENERATOR calls.
--
--  Two levels:
--    slim — ~30 most-used functions (~400 tokens)
--    full — comprehensive reference (~2000 tokens)
--
--  Both are plain text, intentionally terse (signatures + 1-line notes).
--  Token estimates assume ~4 chars/token.
--
-- ===========================================================================

local stubs = {}

-- ===========================================================================
-- SLIM
-- ===========================================================================

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

-- ===========================================================================
-- FULL
-- ===========================================================================

stubs.full = [[
=== Luanti API – Core Reference (full) ===
⚠ Token cost: high. Disable when not needed.
Runtime: LuaJIT. pos = {x,y,z}. All coords are integers in most node ops.

-- [ NODE OPS ] --
core.get_node(pos)                              → {name, param1, param2}
core.get_node_or_nil(pos)                       → node | nil
core.set_node(pos, node)                        -- node = {name, param1=0, param2=0}
core.bulk_set_node(positions, node)             -- faster than repeated set_node
core.swap_node(pos, node)                       -- preserves metadata
core.remove_node(pos)                           -- = set "air"
core.get_node_light(pos, timeofday)             → 0..15 | nil
core.get_node_max_level(pos)                    → int
core.get_node_level(pos)                        → int
core.set_node_level(pos, level)
core.add_node_level(pos, amount)
core.find_node_near(pos, radius, nodenames, search_center) → pos | nil
core.find_nodes_in_area(minp, maxp, nodenames, grouped)    → list, counts
core.find_nodes_in_area_under_air(minp, maxp, nodenames)   → list
core.find_nodes_with_meta(minp, maxp)           → {pos,...}
core.get_meta(pos)                              → NodeMetaRef
core.get_node_timer(pos)                        → NodeTimerRef

-- [ REGISTRATION ] --
core.register_node("mod:name", def)
-- def fields: description, tiles, groups, sounds, drawtype, paramtype,
--             paramtype2, node_box, selection_box, on_construct,
--             on_destruct, after_place_node, after_dig_node,
--             on_punch, on_rightclick, on_timer, light_source,
--             walkable, pointable, diggable, climbable, drowning,
--             damage_per_second, liquid_*, use_texture_alpha
core.register_tool("mod:name", def)
-- def fields: description, inventory_image, stack_max,
--             on_use, on_secondary_use, on_drop, groups,
--             tool_capabilities = {full_punch_interval, max_drop_level,
--               groupcaps={cracky={times={[1]=N,[2]=N,[3]=N}, uses=N, maxlevel=N}}}
core.register_craftitem("mod:name", def)
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
--   :get_acceleration() :set_acceleration(v)
--   :punch(puncher, time_from_last_punch, tool_caps, dir)
--   :remove()  :get_hp()  :set_hp(hp, reason)
--   :get_armor_groups()  :set_armor_groups(groups)
--   :set_properties(prop)  :get_properties()
-- LuaEntitySAO extras: :get_luaentity()  :set_sprite(p, num, framedur, select_horiz)
-- PlayerSAO extras (all methods from ObjectRef plus):
--   :get_player_name()  :get_look_dir()  :get_look_horizontal()
--   :set_look_horizontal(rad)  :get_look_vertical()  :set_look_vertical(rad)
--   :get_inventory()  :get_wielded_item()  :set_wielded_item(item)
--   :get_player_control()  → {up,down,left,right,jump,aux1,sneak,dig,place,zoom}
--   :get_breath()  :set_breath(val)
--   :hud_add(def)  :hud_remove(id)  :hud_change(id, stat, value)
--   :set_sky(params)  :set_sun(params)  :set_moon(params)  :set_stars(params)
--   :set_physics_override(params)

-- [ WORLD MANIPULATION ] --
core.set_node(pos, node)                        -- (see NODE OPS)
core.bulk_set_node(positions, node)
core.place_node(pos, node)                      -- triggers callbacks
core.dig_node(pos)                              -- triggers callbacks, drops items
core.punch_node(pos)
core.emerge_area(minp, maxp, callback)          -- load/gen area async
core.delete_area(minp, maxp)                    -- remove all mapblocks in area
core.load_area(minp, maxp)                      -- load without generating
core.get_mapgen_object(objname)                 → value
core.get_spawn_level(x, z)                      → y | nil

-- [ INVENTORY & ITEMS ] --
core.get_inventory({type="player", name=name})  → InvRef
core.get_inventory({type="node", pos=pos})      → InvRef
-- InvRef: :get_list(listname)  :set_list(listname, list)
--         :get_stack(listname, i)  :set_stack(listname, i, stack)
--         :add_item(listname, item)  :remove_item(listname, item)
--         :get_size(listname)  :set_size(listname, size)
--         :is_empty(listname)  :contains_item(listname, item)
ItemStack(item)                                 → ItemStack
-- ItemStack: :get_name()  :get_count()  :get_wear()  :get_meta()
--            :set_name(n)  :set_count(c)  :set_wear(w)
--            :is_empty()  :is_known()  :to_string()
core.item_place(itemstack, placer, pointed_thing, param2)
core.item_drop(itemstack, dropper, pos)

-- [ FORMSPEC ] --
core.show_formspec(name, formname, formspec)
core.close_formspec(name, formname)
-- Formspec elements (v6+): formspec_version[N] size[W,H] bgcolor[color;fullscreen]
--   label[x,y;text]  button[x,y;w,h;name;label]  image_button[x,y;w,h;img;name;label]
--   field[x,y;w,h;name;label;default]  textarea[x,y;w,h;name;label;default]
--   checkbox[x,y;name;label;selected]  dropdown[x,y;w,h;name;items;selected_idx]
--   image[x,y;w,h;texture]  item_image[x,y;w,h;itemname]
--   box[x,y;w,h;color]  style[name;key=val]  style_type[type;key=val]
--   tooltip[name;text]  scroll_container[x,y;w,h;scrollbar;orientation;factor]

-- [ TIMING & ASYNC ] --
core.after(delay, func, ...)                    → JobRef (:cancel())
core.get_gametime()                             → seconds since world creation
core.get_timeofday()                            → 0..1 (0=midnight, 0.5=noon)
core.set_timeofday(val)
core.get_day_count()                            → int

-- [ ENVIRONMENT ] --
core.get_player_by_name(name)                   → ObjectRef | nil
core.get_connected_players()                    → {ObjectRef,...}
core.get_modpath(modname)                       → string | nil
core.get_modnames()                             → {string,...}
core.get_worldpath()                            → string
core.is_singleplayer()                          → bool
core.get_version()                              → {project, string, hash}
core.get_game_info()                            → {id, title, ...}
core.get_server_info()                          → {address, ip, port, proto_ver}
core.get_player_privs(name)                     → {priv=true,...}
core.get_player_information(name)               → {address, ip, ...}
core.ban_player(name)
core.kick_player(name, reason)

-- [ SOUNDS ] --
core.sound_play(spec, params, ephemeral)        → handle
-- spec: "name" or {name="", gain=1.0, pitch=1.0}
-- params: {to_player=name, pos=pos, max_hear_distance=32, loop=false}
core.sound_stop(handle)
core.sound_fade(handle, step, gain)

-- [ UTILITY ] --
core.log(level, msg)                            -- "none","error","warning","action","info","verbose"
core.debug(...)                                 -- prints to log
core.safe_file_write(path, content)             → bool
core.colorize(color, msg)                       → string
core.get_color_escape_sequence(color)           → string
core.encode_base64(str)                         → string
core.decode_base64(str)                         → string | nil
core.serialize(val)                             → string
core.deserialize(str)                           → value
core.compress(data, method, ...)                → string
core.decompress(data, method, ...)              → string
core.parse_json(str)                            → value
core.write_json(val, styled)                    → string

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
vector.apply(v, func)

-- [ NODE GROUPS (common) ] --
-- cracky=1..3  crumbly=1..3  choppy=1..3  snappy=1..3
-- oddly_breakable_by_hand=1..3  dig_immediate=2..3
-- not_in_creative_inventory=1  attached_node=1  falling_node=1
-- disable_jump=1  liquid=1  water=1  lava=1  igniter=1  flammable=1

-- [ DRAWTYPE VALUES ] --
-- normal  airlike  allfaces  allfaces_optional  glasslike
-- glasslike_framed  torchlike  signlike  plantlike  plantlike_rooted
-- firelike  fencelike  raillike  nodebox  mesh  liquid  flowingliquid

-- [ PARAMTYPE2 VALUES ] --
-- none  facedir  wallmounted  leveled  degrotate
-- meshoptions  color  colorfacedir  colorwallmounted

=== END API (full) ===
]]

return stubs
