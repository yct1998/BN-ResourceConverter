---@diagnostic disable: undefined-global

local mod = game.mod_runtime[game.current_mod]
local storage = game.mod_storage[game.current_mod]

storage.ab_resource_converter_loaded = storage.ab_resource_converter_loaded or false

game.iuse_functions["AB_RESOURCE_CONVERTER_MENU"] = {
    use = function( params )
        return mod.use_machine_menu( params.user, params.item, params.pos )
    end
}

game.iuse_functions["AB_RESOURCE_CONVERTER_STONE_MENU"] = {
    use = function( params )
        return mod.use_stone_menu( params.user, params.item, params.pos )
    end
}

gdebug.log_info( "AB_RESOURCE_CONVERTER: preload complete" )
