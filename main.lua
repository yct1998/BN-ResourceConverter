---@diagnostic disable: undefined-global

gdebug.log_info( "AB_RESOURCE_CONVERTER: main loaded" )

local mod = game.mod_runtime[game.current_mod]
local storage = game.mod_storage[game.current_mod]
local gettext = locale.gettext

local META_OK, catalog_meta = pcall( require, "generated_catalog" )
if not META_OK or type( catalog_meta ) ~= "table" then
    catalog_meta = {
        generated_at = "unknown",
        categories = {},
        source_root = "unknown",
    }
end

local CATEGORY_ITEMS_OK, catalog_category_items = pcall( require, "generated_catalog_category_items" )
if not CATEGORY_ITEMS_OK or type( catalog_category_items ) ~= "table" then
    catalog_category_items = {}
end

local ITEMS_OK, catalog_items = pcall( require, "generated_catalog_items" )
if not ITEMS_OK or type( catalog_items ) ~= "table" then
    catalog_items = {}
end

local CATEGORIES = catalog_meta.categories or {}
local CATEGORY_ITEMS = catalog_category_items or {}
local CATALOG_ITEMS = catalog_items or {}

local MACHINE_NAME = gettext( "资源转换机" )
local STONE_NAME = gettext( "贤者之石" )
local RECYCLE_RADIUS = 1
local PAGE_SIZE = 30

local total_catalog_items = 0
local category_name_by_id = {}
for _, category in ipairs( CATEGORIES ) do
    total_catalog_items = total_catalog_items + ( tonumber( category.count ) or 0 )
    category_name_by_id[category.id] = category.name or category.id
end
if total_catalog_items <= 0 then
    for _ in pairs( CATALOG_ITEMS ) do
        total_catalog_items = total_catalog_items + 1
    end
end

local function ensure_storage_defaults()
    storage.total_recycled_items = storage.total_recycled_items or 0
    storage.total_recycled_money = storage.total_recycled_money or 0
    storage.total_purchased_bundles = storage.total_purchased_bundles or 0
    storage.total_spent_money = storage.total_spent_money or 0
    storage.recycle_multiplier = tonumber( storage.recycle_multiplier ) or 0.5
    storage.buy_multiplier = tonumber( storage.buy_multiplier ) or 2.0
    storage.list_sort_mode = storage.list_sort_mode or "name"
end

local function format_cash( cents, color )
    local amount = tonumber( cents ) or 0
    local text = string.format( "$%.2f", amount / 100 )
    if color and color ~= "" then
        return string.format( "<color_%s>%s</color>", color, text )
    end
    return text
end

local function format_multiplier( value )
    return string.format( "%.2f", tonumber( value ) or 0 )
end

local function popup_message( text )
    local popup = QueryPopup.new()
    popup:message( text )
    popup:allow_any_key( true )
    popup:query()
end

local function confirm_message( text )
    local popup = QueryPopup.new()
    popup:message( text )
    return popup:query_yn() == "YES"
end

local function query_int_value( title_text, desc_text, default_value )
    local popup = PopupInputStr.new()
    popup:title( title_text )
    popup:desc( desc_text )
    local value = popup:query_int()
    if value <= 0 then
        return default_value, false
    end
    return value, true
end

local function query_text_value( title_text, desc_text, default_value )
    title_text = tostring( title_text or "" )
    desc_text = tostring( desc_text or "" )
    default_value = tostring( default_value or "" )
    local _ = default_value

    local popup = PopupInputStr.new()
    popup:title( title_text )
    popup:desc( desc_text )

    local value = popup:query_str()
    if type( value ) == "string" then
        local trimmed = value:gsub( "^%s+", "" ):gsub( "%s+$", "" )
        if trimmed ~= "" then
            return trimmed, true
        end
    end

    return nil, false
end

local function safe_item_name( item, fallback )
    local name = fallback or gettext( "未知物品" )
    if not item then
        return name
    end
    pcall( function()
        name = item:tname( 1, false, 0 )
    end )
    return name
end

local function safe_item_id( item )
    local item_id = nil
    if not item then
        return nil
    end
    pcall( function()
        item_id = item:get_type():str()
    end )
    return item_id
end

local function safe_item_charges( item )
    local charges = 0
    if not item then
        return charges
    end
    pcall( function()
        charges = tonumber( item.charges ) or 0
    end )
    return charges
end

local function get_standard_units( item_data )
    local units = tonumber( item_data and item_data.default_units ) or 1
    if units < 1 then
        units = 1
    end
    return math.floor( units )
end

local function get_item_buy_price( item_data )
    local base_price = tonumber( item_data and item_data.price ) or 0
    return math.max( 0, math.floor( base_price * ( tonumber( storage.buy_multiplier ) or 2.0 ) ) )
end

local function get_sort_mode_label( sort_mode )
    if sort_mode == "price" then
        return gettext( "价格" )
    end
    return gettext( "字母" )
end

local function sort_item_ids( item_ids, sort_mode )
    local sorted = {}
    for _, item_id in ipairs( item_ids ) do
        table.insert( sorted, item_id )
    end

    table.sort( sorted, function( a, b )
        local item_a = CATALOG_ITEMS[a] or {}
        local item_b = CATALOG_ITEMS[b] or {}

        if sort_mode == "price" then
            local price_a = get_item_buy_price( item_a )
            local price_b = get_item_buy_price( item_b )
            if price_a ~= price_b then
                return price_a < price_b
            end
        end

        local name_a = string.lower( tostring( item_a.name or a ) )
        local name_b = string.lower( tostring( item_b.name or b ) )
        if name_a == name_b then
            return a < b
        end
        return name_a < name_b
    end )

    return sorted
end

local function get_category_record( category_id )
    for _, category in ipairs( CATEGORIES ) do
        if category.id == category_id then
            return category
        end
    end
    return {
        id = category_id,
        name = category_name_by_id[category_id] or category_id,
        desc = "",
        count = #( CATEGORY_ITEMS[category_id] or {} ),
    }
end

local function calculate_recycle_value( item, item_data )
    local minimum_value = 1
    local base_value = nil

    if item and type( item.price ) == "function" then
        local ok_price, raw_price = pcall( function()
            return item:price( false )
        end )
        if ok_price and type( raw_price ) == "number" then
            base_value = math.floor( raw_price )
        end
    end

    if not base_value then
        base_value = item_data and tonumber( item_data.price ) or minimum_value
    end

    local recycle_value = math.floor( base_value * ( tonumber( storage.recycle_multiplier ) or 0.5 ) )

    if item_data and item_data.stackable then
        local charges = safe_item_charges( item )
        local standard_units = get_standard_units( item_data )
        if charges > 0 and standard_units > 0 then
            recycle_value = math.floor( recycle_value * ( charges / standard_units ) )
        end
    end

    return math.max( minimum_value, recycle_value )
end

local function collect_recyclables( origin_pos, radius, include_origin )
    local map = gapi.get_map()
    local entries = {}
    local total_value = 0

    for _, point in ipairs( map:points_in_radius( origin_pos, radius ) ) do
        local is_origin = point.z == origin_pos.z and point.x == origin_pos.x and point.y == origin_pos.y
        if point.z == origin_pos.z and ( include_origin or not is_origin ) then
            local map_stack = map:get_items_at( point )
            if map_stack then
                local items = map_stack:items()
                if items then
                    for _, map_item in ipairs( items ) do
                        local item_id = safe_item_id( map_item )
                        local item_data = item_id and CATALOG_ITEMS[item_id] or nil
                        local recycle_value = calculate_recycle_value( map_item, item_data )
                        if recycle_value > 0 then
                            table.insert( entries, {
                                pos = point,
                                item = map_item,
                                id = item_id,
                                name = safe_item_name( map_item, ( item_data and item_data.name ) or item_id or gettext( "未知物品" ) ),
                                value = recycle_value,
                            } )
                            total_value = total_value + recycle_value
                        end
                    end
                end
            end
        end
    end

    table.sort( entries, function( a, b )
        if a.value == b.value then
            return a.name < b.name
        end
        return a.value > b.value
    end )

    return entries, total_value
end

local function run_recycle_menu( who, origin_pos, radius, include_origin, source_name )
    local entries, total_value = collect_recyclables( origin_pos, radius, include_origin )
    if #entries == 0 then
        popup_message( gettext( "范围内没有找到可回收物品。" ) )
        return
    end

    local preview_lines = {
        string.format( gettext( "%s扫描完成。" ), source_name ),
        string.format( gettext( "可回收物品数量: <color_yellow>%d</color>" ), #entries ),
        string.format( gettext( "当前回收倍率: %s" ), format_multiplier( storage.recycle_multiplier ) ),
        string.format( gettext( "预计入账金额: %s" ), format_cash( total_value, "light_green" ) ),
        gettext( "价格规则: 优先读取物品自身 price(false)；失败时回退到目录价格；最低保底 $0.01。" ),
        "",
        gettext( "回收预览:" ),
    }

    local preview_count = math.min( 12, #entries )
    for index = 1, preview_count do
        local entry = entries[index]
        table.insert( preview_lines, string.format( gettext( "%d. %s -> %s" ), index, entry.name, format_cash( entry.value, "yellow" ) ) )
    end
    if #entries > preview_count then
        table.insert( preview_lines, string.format( gettext( "……其余 %d 项将在确认后一并处理。" ), #entries - preview_count ) )
    end

    table.insert( preview_lines, "" )
    table.insert( preview_lines, gettext( "启动回收程序？" ) )

    if not confirm_message( table.concat( preview_lines, "\n" ) ) then
        return
    end

    local map = gapi.get_map()
    for _, entry in ipairs( entries ) do
        map:remove_item_at( entry.pos, entry.item )
    end

    who.cash = who.cash + total_value
    storage.total_recycled_items = storage.total_recycled_items + #entries
    storage.total_recycled_money = storage.total_recycled_money + total_value

    local wait_moves = math.max( 100, #entries * 25 )
    who:assign_activity(
        ActivityTypeId.new( "ACT_WAIT" ),
        wait_moves,
        0,
        0,
        string.format( gettext( "%s回收中 (%s)" ), source_name, format_cash( total_value ) )
    )

    gapi.add_msg(
        MsgType.good,
        string.format( gettext( "%s已完成回收，%d 件物品折算入账 %s。" ), source_name, #entries, format_cash( total_value ) )
    )
end

local function add_or_drop_item( who, spawn_pos, detached_item )
    local can_fit_volume = true
    local can_fit_weight = true

    pcall( function()
        can_fit_volume = who:can_pick_volume( detached_item:volume() )
    end )
    pcall( function()
        can_fit_weight = who:can_pick_weight( detached_item:weight(), false )
    end )

    if can_fit_volume and can_fit_weight then
        who:add_item( detached_item )
        return "inventory"
    end

    gapi.get_map():add_item( spawn_pos, detached_item )
    return "ground"
end

local function perform_purchase( who, spawn_pos, item_data, bundles )
    bundles = math.max( 1, math.floor( tonumber( bundles ) or 1 ) )

    local per_bundle_price = get_item_buy_price( item_data )
    local total_cost = per_bundle_price * bundles
    if total_cost <= 0 then
        popup_message( gettext( "该物品当前没有可用的转换价格。" ) )
        return
    end

    if who.cash < total_cost then
        popup_message(
            string.format(
                gettext( "银行账户余额不足。\n\n当前余额: %s\n所需金额: %s" ),
                format_cash( who.cash, "yellow" ),
                format_cash( total_cost, "light_red" )
            )
        )
        return
    end

    local quantity_text
    if item_data.stackable then
        quantity_text = string.format( gettext( "%d 份标准包（每份 %d 单位）" ), bundles, get_standard_units( item_data ) )
    else
        quantity_text = string.format( gettext( "%d 件" ), bundles )
    end

    local confirm_text = string.format(
        gettext( "确认转换以下物品？\n\n物品: %s\n数量: %s\n基础价格: %s\n当前转换倍率: %s\n转换价: %s\n支付后余额: %s" ),
        item_data.name or item_data.id,
        quantity_text,
        format_cash( item_data.price or 0, "yellow" ),
        format_multiplier( storage.buy_multiplier ),
        format_cash( total_cost, "light_green" ),
        format_cash( who.cash - total_cost, "yellow" )
    )
    if not confirm_message( confirm_text ) then
        return
    end

    local spawned_count = 0
    local dropped_count = 0

    for _ = 1, bundles do
        local spawn_count = item_data.stackable and get_standard_units( item_data ) or 1
        local detached_item = gapi.create_item( ItypeId.new( item_data.id ), spawn_count )
        if detached_item then
            local destination = add_or_drop_item( who, spawn_pos, detached_item )
            if destination == "ground" then
                dropped_count = dropped_count + 1
            end
            spawned_count = spawned_count + 1
        end
    end

    if spawned_count <= 0 then
        popup_message( gettext( "转换失败：目标物品未能生成。" ) )
        return
    end

    local final_cost = per_bundle_price * spawned_count
    who.cash = who.cash - final_cost

    storage.total_purchased_bundles = storage.total_purchased_bundles + spawned_count
    storage.total_spent_money = storage.total_spent_money + final_cost

    local result_lines = {
        string.format( gettext( "已成功转换: %s" ), item_data.name or item_data.id ),
        string.format( gettext( "到账数量: %d 份" ), spawned_count ),
        string.format( gettext( "实际扣款: %s" ), format_cash( final_cost, "light_green" ) ),
        string.format( gettext( "剩余余额: %s" ), format_cash( who.cash, "yellow" ) ),
    }
    if dropped_count > 0 then
        table.insert( result_lines, string.format( gettext( "其中 %d 份因背包空间不足掉落在你脚边。" ), dropped_count ) )
    end

    popup_message( table.concat( result_lines, "\n" ) )
end

local function ask_purchase_quantity( item_data )
    local default_quantity = 1
    local desc_text
    if item_data.stackable then
        desc_text = string.format(
            gettext( "输入购买份数。\n每份会生成 %d 单位。\n当前转换倍率: %s" ),
            get_standard_units( item_data ),
            format_multiplier( storage.buy_multiplier )
        )
    else
        desc_text = string.format( gettext( "输入购买件数。\n当前转换倍率: %s" ), format_multiplier( storage.buy_multiplier ) )
    end

    local quantity, ok = query_int_value(
        string.format( gettext( "输入 %s 的购买数量" ), item_data.name or item_data.id ),
        desc_text,
        default_quantity
    )
    if not ok then
        return nil
    end
    return math.max( 1, quantity )
end

local function open_item_detail_menu( who, spawn_pos, item_id )
    local item_data = CATALOG_ITEMS[item_id]
    if not item_data then
        popup_message( gettext( "未找到该物品的目录数据。" ) )
        return
    end

    local category_name = category_name_by_id[item_data.category] or item_data.category or gettext( "未分类" )
    local standard_text = item_data.stackable
        and string.format( gettext( "%d 单位 / 份" ), get_standard_units( item_data ) )
        or gettext( "1 件 / 份" )

    while true do
        local buy_price = get_item_buy_price( item_data )
        local recycle_price = calculate_recycle_value( gapi.create_item( ItypeId.new( item_data.id ), get_standard_units( item_data ) ), item_data )

        local menu = UiList.new()
        menu:title( item_data.name or item_data.id )
        menu:text(
            string.format(
                gettext( "银行余额: %s\n分类: %s\n类型: %s\n标准份额: %s\n基础价格: %s\n当前转换倍率: %s\n当前回收倍率: %s\n当前转换价: %s\n估算回收价: %s\n重量: %s\n体积: %s\n来源: %s\n\n%s" ),
                format_cash( who.cash, "yellow" ),
                category_name,
                item_data.type or "UNKNOWN",
                standard_text,
                format_cash( item_data.price or 0, "yellow" ),
                format_multiplier( storage.buy_multiplier ),
                format_multiplier( storage.recycle_multiplier ),
                format_cash( buy_price, "light_green" ),
                format_cash( recycle_price, "yellow" ),
                item_data.weight ~= "" and item_data.weight or gettext( "未知" ),
                item_data.volume ~= "" and item_data.volume or gettext( "未知" ),
                item_data.source ~= "" and item_data.source or gettext( "未知" ),
                ( item_data.description ~= "" and item_data.description ) or gettext( "没有额外描述。" )
            )
        )

        menu:add( 1, string.format( gettext( "转换 1 份 (%s)" ), format_cash( buy_price, "light_green" ) ) )
        menu:add( 2, string.format( gettext( "转换 5 份 (%s)" ), format_cash( buy_price * 5, "light_green" ) ) )
        menu:add( 3, gettext( "自定义数量" ) )
        menu:add( 4, gettext( "返回" ) )

        local choice = menu:query()
        if choice == 1 then
            perform_purchase( who, spawn_pos, item_data, 1 )
        elseif choice == 2 then
            perform_purchase( who, spawn_pos, item_data, 5 )
        elseif choice == 3 then
            local quantity = ask_purchase_quantity( item_data )
            if quantity then
                perform_purchase( who, spawn_pos, item_data, quantity )
            end
        else
            return
        end
    end
end

local function build_search_results( query_text )
    local needle = string.lower( tostring( query_text or "" ) )
    local results = {}
    if needle == "" then
        return results
    end

    for item_id, item_data in pairs( CATALOG_ITEMS ) do
        local name_text = string.lower( tostring( item_data.name or item_id ) )
        local id_text = string.lower( tostring( item_id ) )
        if string.find( name_text, needle, 1, true )
            or string.find( id_text, needle, 1, true ) then
            table.insert( results, item_id )
        end
    end

    table.sort( results, function( a, b )
        local item_a = CATALOG_ITEMS[a]
        local item_b = CATALOG_ITEMS[b]
        local name_a = string.lower( tostring( item_a and item_a.name or a ) )
        local name_b = string.lower( tostring( item_b and item_b.name or b ) )
        if name_a == name_b then
            return a < b
        end
        return name_a < name_b
    end )

    return results
end

local function open_item_list_menu( who, spawn_pos, item_ids, title_text, desc_text, back_text )
    if #item_ids == 0 then
        popup_message( gettext( "没有找到可显示的物品。" ) )
        return
    end

    local page = 1

    while true do
        local sorted_item_ids = sort_item_ids( item_ids, storage.list_sort_mode )
        local total_pages = math.max( 1, math.ceil( #sorted_item_ids / PAGE_SIZE ) )
        if page < 1 then
            page = 1
        elseif page > total_pages then
            page = total_pages
        end

        local start_index = ( page - 1 ) * PAGE_SIZE + 1
        local end_index = math.min( #sorted_item_ids, start_index + PAGE_SIZE - 1 )

        local menu = UiList.new()
        menu:title( string.format( gettext( "%s [%d/%d]" ), title_text, page, total_pages ) )
        menu:text(
            string.format(
                gettext( "银行余额: %s\n排序: %s\n%s\n当前页项目: %d - %d / %d" ),
                format_cash( who.cash, "yellow" ),
                get_sort_mode_label( storage.list_sort_mode ),
                desc_text or "",
                start_index,
                end_index,
                #sorted_item_ids
            )
        )

        local sort_index = 9001
        local previous_index = 9002
        local next_index = 9003
        local back_index = 9004

        menu:add( sort_index, string.format( gettext( "切换排序：%s" ), get_sort_mode_label( storage.list_sort_mode ) ) )
        menu:add( previous_index, gettext( "上一页" ) )
        menu:add( next_index, gettext( "下一页" ) )
        menu:add( back_index, back_text or gettext( "返回" ) )

        local index_map = {}
        local menu_index = 1
        for list_index = start_index, end_index do
            local entry_id = sorted_item_ids[list_index]
            local item_data = CATALOG_ITEMS[entry_id]
            if item_data then
                index_map[menu_index] = entry_id
                menu:add(
                    menu_index,
                    string.format( gettext( "%s - %s" ), item_data.name or entry_id, format_cash( get_item_buy_price( item_data ), "light_green" ) )
                )
                menu_index = menu_index + 1
            end
        end

        local choice = menu:query()
        if choice < 1 or choice == back_index then
            return
        elseif choice == sort_index then
            if storage.list_sort_mode == "price" then
                storage.list_sort_mode = "name"
            else
                storage.list_sort_mode = "price"
            end
        elseif choice == previous_index then
            page = page <= 1 and total_pages or ( page - 1 )
        elseif choice == next_index then
            page = page >= total_pages and 1 or ( page + 1 )
        else
            local chosen_id = index_map[choice]
            if chosen_id then
                open_item_detail_menu( who, spawn_pos, chosen_id )
            end
        end
    end
end

local function run_search_menu( who, spawn_pos )
    local query_text, ok = query_text_value(
        gettext( "搜索物品" ),
        gettext( "输入物品名称或 ID 关键词。" ),
        ""
    )
    if not ok or not query_text or query_text == "" then
        popup_message( gettext( "当前环境没有可用的文本输入框，或你取消了搜索输入。" ) )
        return
    end

    local results = build_search_results( query_text )
    if #results == 0 then
        popup_message( string.format( gettext( "没有找到与“%s”匹配的物品。" ), query_text ) )
        return
    end

    open_item_list_menu(
        who,
        spawn_pos,
        results,
        string.format( gettext( "搜索结果: %s" ), query_text ),
        string.format( gettext( "共找到 %d 个匹配项。" ), #results ),
        gettext( "返回分类页" )
    )
end

local function open_category_items_menu( who, spawn_pos, category_id )
    local category = get_category_record( category_id )
    local item_ids = CATEGORY_ITEMS[category_id] or {}
    if #item_ids == 0 then
        popup_message( gettext( "这个分类当前没有可转换的物品。" ) )
        return
    end

    open_item_list_menu( who, spawn_pos, item_ids, category.name or category.id, category.desc or "", gettext( "返回分类列表" ) )
end

local function configure_multipliers()
    local recycle_percent, recycle_ok = query_int_value(
        gettext( "设置回收倍率（百分比）" ),
        string.format( gettext( "当前回收倍率: %s\n例如输入 50 表示 0.50" ), format_multiplier( storage.recycle_multiplier ) ),
        math.floor( ( storage.recycle_multiplier or 0.5 ) * 100 + 0.5 )
    )
    if recycle_ok then
        storage.recycle_multiplier = math.max( 0, recycle_percent ) / 100.0
    end

    local buy_percent, buy_ok = query_int_value(
        gettext( "设置转换倍率（百分比）" ),
        string.format( gettext( "当前转换倍率: %s\n例如输入 200 表示 2.00" ), format_multiplier( storage.buy_multiplier ) ),
        math.floor( ( storage.buy_multiplier or 2.0 ) * 100 + 0.5 )
    )
    if buy_ok then
        storage.buy_multiplier = math.max( 0, buy_percent ) / 100.0
    end

    popup_message(
        string.format(
            gettext( "倍率已更新。\n\n回收倍率: %s\n转换倍率: %s" ),
            format_multiplier( storage.recycle_multiplier ),
            format_multiplier( storage.buy_multiplier )
        )
    )
end

local function open_conversion_menu( who, spawn_pos )
    if not META_OK or not CATEGORY_ITEMS_OK or not ITEMS_OK or total_catalog_items <= 0 then
        popup_message( gettext( "资源目录尚未生成。\n\n请先运行 mod 内附脚本生成 generated_catalog.lua、generated_catalog_category_items.lua 与 generated_catalog_items.lua。" ) )
        return
    end

    while true do
        local menu = UiList.new()
        menu:title( gettext( "转换物品" ) )
        menu:desc_enabled( true )
        menu:text(
            string.format(
                gettext( "银行余额: %s\n当前转换倍率: %s\n当前回收倍率: %s\n请选择操作。" ),
                format_cash( who.cash, "yellow" ),
                format_multiplier( storage.buy_multiplier ),
                format_multiplier( storage.recycle_multiplier )
            )
        )

        local menu_index = 1
        local index_map = {}

        menu:add_w_desc( menu_index, gettext( "搜索物品" ), gettext( "按物品名称或 ID 搜索全部目录。" ) )
        index_map[menu_index] = "__search__"
        menu_index = menu_index + 1

        menu:add_w_desc( menu_index, gettext( "设置倍率" ), gettext( "手动设置回收倍率与转换倍率。默认回收 0.50，转换 2.00。" ) )
        index_map[menu_index] = "__multiplier__"
        menu_index = menu_index + 1

        for _, category in ipairs( CATEGORIES ) do
            index_map[menu_index] = category.id
            menu:add_w_desc(
                menu_index,
                string.format(
                    gettext( "%s (%d)" ),
                    category.name or category.id,
                    tonumber( category.count ) or #( CATEGORY_ITEMS[category.id] or {} )
                ),
                category.desc or ""
            )
            menu_index = menu_index + 1
        end

        local back_index = menu_index
        menu:add( back_index, gettext( "返回主界面" ) )

        local choice = menu:query()
        if choice < 1 or choice == back_index then
            return
        end

        local action = index_map[choice]
        if action == "__search__" then
            run_search_menu( who, spawn_pos )
        elseif action == "__multiplier__" then
            configure_multipliers()
        elseif action then
            open_category_items_menu( who, spawn_pos, action )
        end
    end
end

local function open_intro_menu()
    local intro_lines = {
        string.format( gettext( "%s / 设备介绍" ), MACHINE_NAME ),
        "",
        gettext( "主界面共 3 个入口:" ),
        gettext( "1. 回收物品：扫描范围内物品并折现。" ),
        gettext( "2. 转换物品：分类，可搜索，可选具体物品并输入购买数量。" ),
        gettext( "3. 设备介绍：查看公式、目录格式与当前存档统计。" ),
        "",
        gettext( "价格规则:" ),
        gettext( "- 回收优先读取物品自身 price(false)。" ),
        gettext( "- 实际回收价 = 物品价值 × 回收倍率。" ),
        gettext( "- 实际转换价 = 基础价格 × 转换倍率。" ),
        gettext( "- 最低保底回收价 = $0.01。" ),
        gettext( "- 默认回收倍率 = 0.50。" ),
        gettext( "- 默认转换倍率 = 2.00。" ),
        "",
        string.format( gettext( "目录规模: %d 个分类 / %d 件物品" ), #CATEGORIES, total_catalog_items ),
        string.format( gettext( "目录生成时间: %s" ), catalog_meta.generated_at or "unknown" ),
        string.format( gettext( "当前回收倍率: %s" ), format_multiplier( storage.recycle_multiplier ) ),
        string.format( gettext( "当前转换倍率: %s" ), format_multiplier( storage.buy_multiplier ) ),
        string.format( gettext( "当前列表排序: %s" ), get_sort_mode_label( storage.list_sort_mode ) ),
        "",
        string.format( gettext( "累计回收件数: %d" ), storage.total_recycled_items or 0 ),
        string.format( gettext( "累计回收入账: %s" ), format_cash( storage.total_recycled_money or 0, "light_green" ) ),
        string.format( gettext( "累计转换份数: %d" ), storage.total_purchased_bundles or 0 ),
        string.format( gettext( "累计转换支出: %s" ), format_cash( storage.total_spent_money or 0, "light_red" ) ),
    }

    popup_message( table.concat( intro_lines, "\n" ) )
end

local function open_machine_menu( who, source_name, recycle_origin_pos, recycle_radius, include_origin, spawn_pos )
    while true do
        local menu = UiList.new()
        menu:title( source_name )
        menu:desc_enabled( true )
        menu:text(
            string.format(
                gettext( "银行余额: %s\n资源目录: %d 个分类 / %d 件物品\n回收倍率: %s\n转换倍率: %s\n请选择功能。" ),
                format_cash( who.cash, "yellow" ),
                #CATEGORIES,
                total_catalog_items,
                format_multiplier( storage.recycle_multiplier ),
                format_multiplier( storage.buy_multiplier )
            )
        )
        menu:add_w_desc( 1, gettext( "回收物品" ), gettext( "读取指定范围内的所有物品；优先按物品自身价值回收，最低保底 $0.01。" ) )
        menu:add_w_desc( 2, gettext( "转换物品" ), gettext( "打开分类目录，可先搜索，再按“基础价格 × 转换倍率”转换出基础游戏物品。" ) )
        menu:add_w_desc( 3, gettext( "设备介绍" ), gettext( "查看三大界面说明、价格公式、目录格式与当前存档统计。" ) )
        menu:add( 4, gettext( "关闭" ) )

        local choice = menu:query()
        if choice == 1 then
            run_recycle_menu( who, recycle_origin_pos, recycle_radius, include_origin, source_name )
        elseif choice == 2 then
            open_conversion_menu( who, spawn_pos )
        elseif choice == 3 then
            open_intro_menu()
        else
            break
        end
    end

    return 0
end

mod.use_machine_menu = function( who, item, pos )
    ensure_storage_defaults()

    if not who or not who:is_avatar() then
        return 0
    end

    local machine_pos = pos or who:get_pos_ms()
    return open_machine_menu( who, MACHINE_NAME, machine_pos, RECYCLE_RADIUS, false, who:get_pos_ms() )
end

mod.use_stone_menu = function( who, item, pos )
    ensure_storage_defaults()

    if not who or not who:is_avatar() then
        return 0
    end

    local player_pos = who:get_pos_ms()
    return open_machine_menu( who, STONE_NAME, player_pos, 0, true, player_pos )
end
