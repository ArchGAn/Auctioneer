addon.name      = 'Auctioneer';
addon.author    = 'Ivaar (v4 port by MoonRise, enhanced by Elo)';
addon.version   = '4.0';
addon.desc      = 'Auction House Helper with Auto-Refresh';

require('common');
local chat = require('chat');
local imgui = require('imgui');
local settings = require('settings');

-- Default Settings
local default_settings = {
    auction_list = {
        visibility = true,
        timer = true,
        date = false,
        price = true,
        empty = false,
        slot = true,
        auto_refresh = true,
        refresh_interval = 30,
        sale_notifications = true,
    }
};

local config = default_settings;
local load_success, load_result = pcall(settings.load, default_settings);
if (load_success and load_result ~= nil) then
    config = load_result;
    config.auction_list.auto_refresh = config.auction_list.auto_refresh ~= false;
    config.auction_list.refresh_interval = config.auction_list.refresh_interval or 30;
    config.auction_list.sale_notifications = config.auction_list.sale_notifications ~= false;
end

-- AH Zone IDs (faster lookup than string comparison)
local ah_zone_ids = {
    [234] = true, [235] = true,  -- Bastok Mines, Bastok Markets
    [252] = true,                 -- Norg
    [230] = true, [232] = true,  -- Southern/Port San d'Oria
    [247] = true,                 -- Rabao
    [241] = true, [239] = true,  -- Windurst Woods/Walls
    [250] = true,                 -- Kazham
    [245] = true, [243] = true,  -- Lower Jeuno, Ru'Lude Gardens
    [246] = true, [244] = true,  -- Port/Upper Jeuno
    [50] = true, [48] = true,    -- Aht Urhgan Whitegate, Al Zahbi
    [53] = true,                  -- Nashmau
    [26] = true,                  -- Tavnazian Safehold
    [256] = true, [257] = true,  -- Western/Eastern Adoulin
};

-- AH NPC/Object names (partial match) - includes various server naming conventions
local ah_npc_patterns = {
    'Auction', 'auction', 'AUCTION',
    'Broker', 'broker',
    'Counter', 'counter',
};

-- AH Configuration (7 slots - standard FFXI protocol)
local AH_TOTAL_SLOTS = 7;

-- State
local auction_box = nil;
local previous_status = {};
local last4E = nil;
local lclock = 0;
local pending_confirm = nil;
local pending_confirm_time = 0;

-- Session tracking
local session_sales = 0;
local session_items_sold = 0;
local last_refresh_time = 0;

-- Refresh state machine (simplified - requires manual AH open first)
local RefreshState = {
    IDLE = 0,
    REFRESHING = 1,
};

local refresh = {
    state = RefreshState.IDLE,
    slot = 0,
    next_action_time = 0,
};

-- Helper Functions
local function comma_value(n)
    local left, num, right = string.match(tostring(n), '^([^%d]*%d)(%d*)(.-)$');
    if (left == nil) then return tostring(n); end
    return left .. (num:reverse():gsub('(%d%d%d)', '%1,'):reverse()) .. right;
end

local function has_flag(n, flag)
    return bit.band(n, flag) == flag;
end

local function item_name(id)
    local item = AshitaCore:GetResourceManager():GetItemById(tonumber(id));
    if (item ~= nil) then
        return item.Name[1] or item.Name[0] or 'Unknown';
    end
    return 'Unknown';
end

local function timef(ts)
    if (ts <= 0) then return 'EXPIRED'; end
    local days = math.floor(ts / (60*60*24));
    local hours = math.floor(ts / (60*60)) % 24;
    local mins = math.floor(ts / 60) % 60;
    if (days > 0) then
        return string.format('%dd %dh', days, hours);
    elseif (hours > 0) then
        return string.format('%dh %dm', hours, mins);
    else
        return string.format('%dm', mins);
    end
end

local function time_ago(ts)
    local diff = os.time() - ts;
    if (diff < 60) then return 'just now'; end
    if (diff < 3600) then return string.format('%dm ago', math.floor(diff / 60)); end
    if (diff < 86400) then return string.format('%dh ago', math.floor(diff / 3600)); end
    return string.format('%dd ago', math.floor(diff / 86400));
end

local function get_zone_id()
    local party = AshitaCore:GetMemoryManager():GetParty();
    if (party == nil) then return 0; end
    return party:GetMemberZone(0);
end

local function get_zone_name()
    local zone_id = get_zone_id();
    local zone = AshitaCore:GetResourceManager():GetString('zones.names', zone_id);
    return zone or '';
end

local function is_in_ah_zone()
    return ah_zone_ids[get_zone_id()] == true;
end

local function get_player_position()
    local entity = AshitaCore:GetMemoryManager():GetEntity();
    if (entity == nil) then return nil; end
    local x = entity:GetLocalPositionX(0);
    local y = entity:GetLocalPositionY(0);
    local z = entity:GetLocalPositionZ(0);
    return { x = x, y = y, z = z };
end

local function distance_to(pos1, pos2)
    if (pos1 == nil or pos2 == nil) then return 9999; end
    local dx = pos1.x - pos2.x;
    local dz = pos1.z - pos2.z;
    return math.sqrt(dx * dx + dz * dz);
end

local function find_ah_npc()
    local entity = AshitaCore:GetMemoryManager():GetEntity();
    if (entity == nil) then return nil; end
    
    local player_pos = get_player_position();
    if (player_pos == nil) then return nil; end
    
    local best_npc = nil;
    local best_dist = 999;
    
    -- Scan entities - AH counters are objects, not traditional NPCs
    -- They typically have indices in the NPC range but different spawn flags
    for i = 1, 2048 do
        local render_flags = entity:GetRenderFlags0(i);
        if (render_flags ~= 0 and render_flags ~= nil) then
            local name = entity:GetName(i);
            if (name ~= nil and name ~= '') then
                local is_ah = false;
                for _, pattern in ipairs(ah_npc_patterns) do
                    if (string.find(name, pattern)) then
                        is_ah = true;
                        break;
                    end
                end
                
                if (is_ah) then
                    local npc_x = entity:GetLocalPositionX(i);
                    local npc_z = entity:GetLocalPositionZ(i);
                    local npc_pos = { x = npc_x, z = npc_z };
                    local dist = distance_to(player_pos, npc_pos);
                    
                    if (dist < best_dist and dist < 10) then  -- Within 10 yalms
                        best_dist = dist;
                        best_npc = {
                            index = i,
                            server_id = entity:GetServerId(i),
                            name = name,
                            distance = dist,
                        };
                    end
                end
            end
        end
    end
    
    return best_npc;
end

local function find_empty_slot()
    if (auction_box == nil) then return nil; end
    for slot = 0, AH_TOTAL_SLOTS - 1 do
        if (auction_box[slot] ~= nil and auction_box[slot].status == 'Empty') then
            return slot;
        end
    end
    return nil;
end

local function find_item(item_id, item_count)
    local inv = AshitaCore:GetMemoryManager():GetInventory();
    if (inv == nil) then return nil; end
    for ind = 1, 80 do
        local item = inv:GetContainerItem(0, ind);
        if (item ~= nil and item.Id == item_id and item.Flags == 0 and item.Count >= item_count) then
            return ind;
        end
    end
    return nil;
end

-- Packet sending helpers
local function send_slot_query(slot)
    local pkt = struct.pack('bbxxbbi32i22', 0x4E, 0x1E, 0x0A, slot, 0x00, 0x00):totable();
    AshitaCore:GetPacketManager():AddOutgoingPacket(0x4E, pkt);
end

-- Refresh control
local function start_refresh()
    if (not is_in_ah_zone()) then
        print(chat.header('Auctioneer'):append(chat.warning('Must be in AH zone to refresh.')));
        return false;
    end
    
    if (refresh.state ~= RefreshState.IDLE) then
        return false;
    end
    
    if (auction_box == nil) then
        print(chat.header('Auctioneer'):append(chat.warning('Open AH menu first to initialize.')));
        return false;
    end
    
    refresh.state = RefreshState.REFRESHING;
    refresh.slot = 0;
    refresh.next_action_time = os.clock() + 0.1;
    return true;
end

local function cancel_refresh()
    refresh.state = RefreshState.IDLE;
end

local function update_sales_status(packet)
    local slot = packet:byte(0x05 + 1);
    local status = packet:byte(0x14 + 1);
    
    if (auction_box == nil) then
        auction_box = {};
        for i = 0, AH_TOTAL_SLOTS - 1 do
            auction_box[i] = { status = 'Empty' };
        end
    end
    
    if (slot >= AH_TOTAL_SLOTS or status == 0x02 or status == 0x04 or status == 0x10) then
        return;
    end
    
    if (auction_box[slot] == nil) then
        auction_box[slot] = {};
    end
    
    local old_status = previous_status[slot];
    local new_status = nil;
    local item_sold_name = nil;
    local item_sold_price = 0;
    
    if (status == 0x00) then
        new_status = 'Empty';
        auction_box[slot] = { status = 'Empty' };
    else
        if (status == 0x03) then
            new_status = 'On auction';
            auction_box[slot].status = 'On auction';
        elseif (status == 0x0A or status == 0x0C or status == 0x15) then
            new_status = 'Sold';
            auction_box[slot].status = 'Sold';
        elseif (status == 0x0B or status == 0x0D or status == 0x16) then
            new_status = 'Not Sold';
            auction_box[slot].status = 'Not Sold';
        end
        
        auction_box[slot].item = item_name(struct.unpack('h', packet, 0x28 + 1));
        auction_box[slot].count = packet:byte(0x2A + 1);
        auction_box[slot].price = struct.unpack('i', packet, 0x2C + 1);
        auction_box[slot].timestamp = struct.unpack('I', packet, 0x38 + 1);
        auction_box[slot].last_update = os.time();
        
        -- Track first seen for timer estimation
        local current_item = auction_box[slot].item;
        local current_price = auction_box[slot].price;
        if (not auction_box[slot].first_seen or 
            auction_box[slot].tracked_item ~= current_item or 
            auction_box[slot].tracked_price ~= current_price) then
            auction_box[slot].first_seen = os.time();
            auction_box[slot].tracked_item = current_item;
            auction_box[slot].tracked_price = current_price;
        end
        
        item_sold_name = auction_box[slot].item;
        item_sold_price = auction_box[slot].price;
    end
    
    -- Sale notifications
    if (config.auction_list.sale_notifications) then
        if (old_status == 'On auction' and new_status == 'Sold') then
            session_sales = session_sales + (item_sold_price or 0);
            session_items_sold = session_items_sold + 1;
            print(chat.header('Auctioneer'):append(chat.success(string.format('SOLD! %s for %sg', 
                item_sold_name or 'Item', comma_value(item_sold_price or 0)))));
        elseif (old_status == 'On auction' and new_status == 'Not Sold') then
            print(chat.header('Auctioneer'):append(chat.warning(string.format('Expired: %s', item_sold_name or 'Item'))));
        end
    end
    
    previous_status[slot] = new_status;
    last_refresh_time = os.time();
end

-- Clear queue for sold/expired items (needs delays between packets)
local clear_queue = {};
local clear_next_time = 0;

local function queue_clear_sales()
    if (auction_box == nil) then return 0; end
    clear_queue = {};
    for slot = 0, AH_TOTAL_SLOTS - 1 do
        if (auction_box[slot] ~= nil and (auction_box[slot].status == 'Sold' or auction_box[slot].status == 'Not Sold')) then
            table.insert(clear_queue, slot);
        end
    end
    if (#clear_queue > 0) then
        clear_next_time = os.clock() + 0.1;
    end
    return #clear_queue;
end

local function process_clear_queue()
    if (#clear_queue > 0 and os.clock() >= clear_next_time) then
        local slot = table.remove(clear_queue, 1);
        print(chat.header('Auctioneer'):append(chat.message(string.format('Clearing slot %d...', slot + 1))));
        local pkt = struct.pack('bbxxbbi32i22', 0x4E, 0x1E, 0x10, slot, 0x00, 0x00):totable();
        AshitaCore:GetPacketManager():AddOutgoingPacket(0x4E, pkt);
        clear_next_time = os.clock() + 0.5;  -- 500ms between clears
    end
end

-- GUI State
local gui = {
    main_open = { config.auction_list.visibility },
    settings_open = { false },
    show_empty = { config.auction_list.empty },
    show_price = { config.auction_list.price },
    show_timer = { config.auction_list.timer },
    show_date = { config.auction_list.date or false },
    auto_refresh = { config.auction_list.auto_refresh },
    refresh_interval = { config.auction_list.refresh_interval },
    sale_notifications = { config.auction_list.sale_notifications },
};

local function ah_proposal(bid, name, vol, price)
    local item = AshitaCore:GetResourceManager():GetItemByName(name, 2);
    if (item == nil) then 
        print(chat.header('Auctioneer'):append(chat.error(string.format('"%s" not a valid item name.', name))));
        return false; 
    end

    if (has_flag(item.Flags, 0x4000)) then
        print(chat.header('Auctioneer'):append(chat.error(string.format('%s cannot be sold on AH.', item.Name[1] or item.Name[0]))));
        return false;
    end

    local single;
    if (item.StackSize ~= 1 and (vol == '1' or vol:lower() == 'stack')) then
        single = 0;
    elseif (vol == '0' or vol:lower() == 'single') then
        single = 1;
    else 
        print(chat.header('Auctioneer'):append(chat.error('Specify single or stack.')));
        return false;
    end
    
    price = price:gsub('%p', '');
    local price_num = tonumber(price);
    
    local inv = AshitaCore:GetMemoryManager():GetInventory();
    local gil = inv:GetContainerItem(0, 0).Count;
    
    if (price_num == nil or price_num < 1) then
        print(chat.header('Auctioneer'):append(chat.error('Invalid price.')));
        return false;
    end
    
    if (bid == 'sell' and price_num > 999999999) then
        print(chat.header('Auctioneer'):append(chat.error('Price too high (max 999,999,999).')));
        return false;
    end
    
    if (bid == 'buy' and price_num > gil) then
        print(chat.header('Auctioneer'):append(chat.error('Not enough gil.')));
        return false;
    end

    local item_name_str = item.Name[1] or item.Name[0];
    local trans;
    
    if (bid == 'buy') then
        local slot = find_empty_slot();
        if (slot == nil) then slot = 0x07; end
        trans = struct.pack('bbxxihxx', 0x0E, slot, price_num, item.Id);
        print(chat.header('Auctioneer'):append(chat.message(string.format('Buying "%s" for %s [%s]', 
            item_name_str, comma_value(price_num), single == 1 and 'Single' or 'Stack'))));
            
    elseif (bid == 'sell') then
        if (auction_box == nil) then
            print(chat.header('Auctioneer'):append(chat.error('Click auction counter or /ah refresh to initialize.')));
            return false;
        end
        if (find_empty_slot() == nil) then 
            print(chat.header('Auctioneer'):append(chat.error('No empty slots available.')));
            return false;
        end
        local count_needed = single == 1 and 1 or item.StackSize;
        local index = find_item(item.Id, count_needed);
        if (index == nil) then 
            print(chat.header('Auctioneer'):append(chat.error(string.format('%s of %s not in inventory.', 
                single == 1 and 'Single' or 'Stack', item_name_str))));
            return false;
        end
        trans = struct.pack('bxxxihh', 0x04, price_num, index, item.Id);
        print(chat.header('Auctioneer'):append(chat.message(string.format('Selling "%s" for %s [%s]', 
            item_name_str, comma_value(price_num), single == 1 and 'Single' or 'Stack'))));
    else 
        return false; 
    end
    
    trans = struct.pack('bbxx', 0x4E, 0x1E) .. trans .. struct.pack('bi32i11', single, 0x00, 0x00);
    
    if (bid == 'sell') then
        last4E = trans;
    end
    
    AshitaCore:GetPacketManager():AddOutgoingPacket(0x4E, trans:totable());
    return true;
end

-- Packet Handler
ashita.events.register('packet_in', 'auctioneer_packet_in', function(e)
    if (e.id == 0x4C) then
        local pType = e.data:byte(5);
        local response = e.data:byte(7);
        
        -- AH menu opened
        if (pType == 0x02 and response == 0x01) then
            if (auction_box == nil) then
                auction_box = {};
                for i = 0, AH_TOTAL_SLOTS - 1 do
                    auction_box[i] = { status = 'Empty' };
                    previous_status[i] = 'Empty';
                end
            end
            
            -- Start refresh cycle
            if (refresh.state == RefreshState.IDLE) then
                refresh.state = RefreshState.REFRESHING;
                refresh.slot = 0;
                refresh.next_action_time = os.clock() + 0.3;
            end
        end
        
        -- Sell confirmation prompt
        if (pType == 0x04) then
            local slot = find_empty_slot();
            local fee = struct.unpack('i', e.data, 9);
            local resp = e.data:byte(7);
            
            if (last4E ~= nil and resp == 0x01 and slot ~= nil and last4E:byte(5) == 0x04) then
                if (e.data:sub(13, 17) == last4E:sub(13, 17)) then
                    local inv = AshitaCore:GetMemoryManager():GetInventory();
                    local gil = inv:GetContainerItem(0, 0).Count;
                    
                    if (gil >= fee) then
                        local sell_confirm = struct.pack('bbxxbbxxbbbbbbxxbi32i11', 
                            0x4E, 0x1E, 0x0B, slot,
                            last4E:byte(9), last4E:byte(10), last4E:byte(11), last4E:byte(12),
                            e.data:byte(13), e.data:byte(14),
                            last4E:byte(17), 0x00, 0x00):totable();
                        
                        pending_confirm = sell_confirm;
                        pending_confirm_time = os.clock() + (math.random() * 0.5 + 0.1);
                        last4E = nil;
                    end
                end
            end
            
        -- Slot status response
        elseif (pType == 0x0A or pType == 0x0B or pType == 0x0C or pType == 0x0D or pType == 0x10) then
            if (e.data:byte(7) == 0x01) then
                update_sales_status(e.data);
            end
            
        -- Bid response
        elseif (pType == 0x0E) then
            if (e.data:byte(7) == 0x01) then
                print(chat.header('Auctioneer'):append(chat.success('Bid Success!')));
            elseif (e.data:byte(7) == 0xC5) then
                print(chat.header('Auctioneer'):append(chat.error('Bid Failed')));
            end
        end
        
    -- Zone change - clear session
    elseif (e.id == 0x0B) then
        if (e.data:byte(5) == 0x01) then
            auction_box = nil;
            previous_status = {};
            cancel_refresh();
        end
    end
end);

-- Main update loop
ashita.events.register('d3d_present', 'auctioneer_render', function()
    local now = os.clock();
    
    -- Handle pending sell confirmation
    if (pending_confirm ~= nil and now >= pending_confirm_time) then
        AshitaCore:GetPacketManager():AddOutgoingPacket(0x4E, pending_confirm);
        pending_confirm = nil;
        print(chat.header('Auctioneer'):append(chat.success('Sale confirmed!')));
    end
    
    -- Process clear queue
    process_clear_queue();
    
    -- Refresh state machine
    if (refresh.state == RefreshState.REFRESHING and now >= refresh.next_action_time) then
        if (refresh.slot < AH_TOTAL_SLOTS) then
            send_slot_query(refresh.slot);
            refresh.slot = refresh.slot + 1;
            refresh.next_action_time = now + 0.25;
        else
            refresh.state = RefreshState.IDLE;
        end
    end
    
    -- Auto-refresh timer (only when AH is initialized)
    if (gui.auto_refresh[1] and is_in_ah_zone() and auction_box ~= nil and refresh.state == RefreshState.IDLE) then
        local now_time = os.time();
        if (last_refresh_time > 0 and (now_time - last_refresh_time) >= gui.refresh_interval[1]) then
            start_refresh();
        end
    end
    
    -- GUI rendering
    if (config.auction_list.visibility and gui.main_open[1]) then
        imgui.SetNextWindowSize({ 520, 280 }, ImGuiCond_FirstUseEver);
        
        if (imgui.Begin('Auction Box', gui.main_open, ImGuiWindowFlags_None)) then
            -- Header row: Settings, Refresh, Summary
            if (imgui.Button('Settings', { 70, 22 })) then
                gui.settings_open[1] = not gui.settings_open[1];
            end
            imgui.SameLine();
            
            local refresh_label = 'Refresh';
            if (refresh.state == RefreshState.REFRESHING) then
                refresh_label = string.format('%d/%d...', refresh.slot, AH_TOTAL_SLOTS);
            end
            
            if (imgui.Button(refresh_label, { 70, 22 })) then
                if (refresh.state == RefreshState.IDLE) then
                    start_refresh();
                end
            end
            imgui.SameLine();
            
            -- Slot summary
            if (auction_box ~= nil) then
                local used, sold, expired = 0, 0, 0;
                for i = 0, AH_TOTAL_SLOTS - 1 do
                    if (auction_box[i] and auction_box[i].status ~= 'Empty') then
                        used = used + 1;
                        if (auction_box[i].status == 'Sold') then sold = sold + 1;
                        elseif (auction_box[i].status == 'Not Sold') then expired = expired + 1;
                        end
                    end
                end
                imgui.TextColored({ 0.7, 0.7, 0.7, 1.0 }, string.format('Slots: %d/%d', used, AH_TOTAL_SLOTS));
                if (sold > 0) then
                    imgui.SameLine();
                    imgui.TextColored({ 0.2, 1.0, 0.2, 1.0 }, string.format(' [%d SOLD]', sold));
                end
                if (expired > 0) then
                    imgui.SameLine();
                    imgui.TextColored({ 1.0, 0.5, 0.2, 1.0 }, string.format(' [%d EXP]', expired));
                end
            end
            
            if (last_refresh_time > 0) then
                imgui.SameLine();
                imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 }, string.format('  (%s)', time_ago(last_refresh_time)));
            end
            
            imgui.Separator();
            
            -- Main content
            if (auction_box == nil) then
                imgui.TextColored({ 1.0, 0.5, 0.2, 1.0 }, 'No auction data loaded.');
                imgui.Text('Open the Auction House menu to initialize.');
            else
                -- Header
                local header = '   Slot  Status       Item';
                if (gui.show_price[1]) then header = header .. '                              Price'; end
                if (gui.show_timer[1]) then header = header .. '      ~Time'; end
                if (gui.show_date[1]) then header = header .. '       Expires'; end
                imgui.TextColored({ 0.5, 0.8, 1.0, 1.0 }, header);
                imgui.Separator();
                
                for slot = 0, AH_TOTAL_SLOTS - 1 do
                    local info = auction_box[slot];
                    if (info ~= nil) then
                        -- Always show sold/expired, optionally show empty
                        local is_actionable = (info.status == 'Sold' or info.status == 'Not Sold');
                        local show = is_actionable or gui.show_empty[1] or info.status ~= 'Empty';
                        
                        if (show) then
                            local color = { 0.5, 0.5, 0.5, 1.0 };
                            local status_text = info.status or 'Empty';
                            local prefix = '   ';  -- 3 spaces default
                            
                            if (info.status == 'Sold') then
                                color = { 0.2, 1.0, 0.2, 1.0 };  -- Bright green
                                prefix = '>> ';  -- Arrow indicator
                                status_text = 'SOLD!';
                            elseif (info.status == 'Not Sold') then
                                color = { 1.0, 0.4, 0.4, 1.0 };  -- Red
                                prefix = '>> ';
                                status_text = 'EXPIRED';
                            elseif (info.status == 'On auction') then
                                color = { 1.0, 0.9, 0.4, 1.0 };  -- Yellow
                            end
                            
                            local slot_str = string.format('[%d]', slot + 1);
                            local status_str = string.format('%-11s', status_text);
                            
                            if (info.status == 'Empty') then
                                imgui.TextColored(color, string.format('%s%s  %s  ---', prefix, slot_str, status_str));
                            else
                                local item_str = info.item or 'Unknown';
                                local count = info.count or 1;
                                if (count > 1) then
                                    item_str = item_str .. ' x' .. count;
                                end
                                item_str = string.format('%-30s', item_str);
                                
                                local price_str = '';
                                if (gui.show_price[1] and info.price and info.price > 0) then
                                    price_str = string.format('%10s', comma_value(info.price) .. 'g');
                                end
                                
                                local timer_str = '';
                                if (gui.show_timer[1] and info.status == 'On auction' and info.first_seen) then
                                    local expire_time = info.first_seen + 829440;
                                    local remaining = expire_time - os.time();
                                    timer_str = remaining > 0 and ('  ~' .. timef(remaining)) or '  EXPIRED?';
                                end
                                
                                local date_str = '';
                                if (gui.show_date[1] and info.status == 'On auction' and info.first_seen) then
                                    local expire_time = info.first_seen + 829440;
                                    date_str = '  Exp:' .. os.date('%m/%d %H:%M', expire_time);
                                end
                                
                                imgui.TextColored(color, string.format('%s%s  %s  %s  %s%s%s', 
                                    prefix, slot_str, status_str, item_str, price_str, timer_str, date_str));
                            end
                        end
                    end
                end
            end
            
            imgui.Separator();
            
            -- Bottom buttons
            local clear_label = #clear_queue > 0 and string.format('Clearing %d...', #clear_queue) or 'Clear Sold/Expired';
            if (imgui.Button(clear_label, { 130, 25 })) then
                if (#clear_queue > 0) then
                    -- Already clearing
                elseif (auction_box ~= nil and is_in_ah_zone()) then
                    local to_clear = queue_clear_sales();
                    if (to_clear > 0) then
                        print(chat.header('Auctioneer'):append(chat.message(string.format('Queued %d items to clear...', to_clear))));
                    else
                        print(chat.header('Auctioneer'):append(chat.message('Nothing to clear.')));
                    end
                elseif (not is_in_ah_zone()) then
                    print(chat.header('Auctioneer'):append(chat.warning('Must be in AH zone.')));
                end
            end
            imgui.SameLine();
            imgui.Checkbox('Empty', gui.show_empty);
            imgui.SameLine();
            imgui.Checkbox('Prices', gui.show_price);
            imgui.SameLine();
            imgui.Checkbox('Timer', gui.show_timer);
            
            if (session_items_sold > 0) then
                imgui.Separator();
                imgui.TextColored({ 0.2, 1.0, 0.2, 1.0 }, 
                    string.format('Session: %d sold for %sg', session_items_sold, comma_value(session_sales)));
            end
        end
        imgui.End();
    end
    
    -- Settings window
    if (gui.settings_open[1]) then
        imgui.SetNextWindowSize({ 280, 300 }, ImGuiCond_FirstUseEver);
        
        if (imgui.Begin('Auctioneer Settings', gui.settings_open, ImGuiWindowFlags_AlwaysAutoResize)) then
            imgui.Text('Display Options:');
            imgui.Separator();
            
            imgui.Checkbox('Show Empty Slots', gui.show_empty);
            imgui.Checkbox('Show Prices', gui.show_price);
            imgui.Checkbox('Show Time Remaining', gui.show_timer);
            if (gui.show_timer[1]) then
                imgui.TextColored({ 0.6, 0.6, 0.6, 1.0 }, '  (~estimate from first seen)');
            end
            imgui.Checkbox('Show Expiration Date', gui.show_date);
            
            imgui.Separator();
            imgui.Text('Auto-Refresh:');
            imgui.Separator();
            
            imgui.Checkbox('Enable Auto-Refresh', gui.auto_refresh);
            if (gui.auto_refresh[1]) then
                imgui.Text('Interval (seconds):');
                imgui.SliderInt('##interval', gui.refresh_interval, 15, 120);
            end
            imgui.Checkbox('Sale Notifications', gui.sale_notifications);
            
            imgui.Separator();
            
            if (imgui.Button('Save Settings', { 120, 25 })) then
                config.auction_list.empty = gui.show_empty[1];
                config.auction_list.price = gui.show_price[1];
                config.auction_list.timer = gui.show_timer[1];
                config.auction_list.date = gui.show_date[1];
                config.auction_list.auto_refresh = gui.auto_refresh[1];
                config.auction_list.refresh_interval = gui.refresh_interval[1];
                config.auction_list.sale_notifications = gui.sale_notifications[1];
                pcall(settings.save);
                print(chat.header('Auctioneer'):append(chat.message('Settings saved.')));
            end
            imgui.SameLine();
            if (imgui.Button('Close', { 80, 25 })) then
                gui.settings_open[1] = false;
            end
            
            imgui.Separator();
            if (imgui.Button('Reset Session Stats', { 140, 22 })) then
                session_sales = 0;
                session_items_sold = 0;
                print(chat.header('Auctioneer'):append(chat.message('Session stats reset.')));
            end
        end
        imgui.End();
    end
end);

-- Commands
ashita.events.register('command', 'auctioneer_command', function(e)
    local args = e.command:args();
    if (#args == 0) then return; end
    
    local cmd = args[1]:lower();
    
    if (cmd ~= '/ah' and cmd ~= '/buy' and cmd ~= '/sell') then
        return;
    end
    
    e.blocked = true;
    local now = os.clock();
    
    if (cmd == '/ah') then
        if (#args == 1) then
            config.auction_list.visibility = not config.auction_list.visibility;
            gui.main_open[1] = config.auction_list.visibility;
            return;
        end
        
        local subcmd = args[2]:lower();
        
        if (subcmd == 'show') then
            config.auction_list.visibility = true;
            gui.main_open[1] = true;
        elseif (subcmd == 'hide') then
            config.auction_list.visibility = false;
            gui.main_open[1] = false;
        elseif (subcmd == 'menu') then
            if (is_in_ah_zone() and (lclock == 0 or lclock < now)) then
                lclock = now + 3;
                local menu = struct.pack('bbbbbbbi32i21', 0x4C, 0x1E, 0x00, 0x00, 0x02, 0x00, 0x01, 0x00, 0x00):totable();
                AshitaCore:GetPacketManager():AddIncomingPacket(0x4C, menu);
            end
        elseif (subcmd == 'refresh') then
            start_refresh();
        elseif (subcmd == 'clear') then
            if (is_in_ah_zone()) then
                local to_clear = queue_clear_sales();
                if (to_clear > 0) then
                    print(chat.header('Auctioneer'):append(chat.message(string.format('Queued %d items to clear...', to_clear))));
                else
                    print(chat.header('Auctioneer'):append(chat.message('Nothing to clear.')));
                end
            else
                print(chat.header('Auctioneer'):append(chat.warning('Must be in AH zone.')));
            end
        elseif (subcmd == 'save') then
            pcall(settings.save);
            print(chat.header('Auctioneer'):append(chat.message('Settings saved.')));
        elseif (subcmd == 'stats') then
            print(chat.header('Auctioneer'):append(chat.message(string.format('Session: %d items sold for %sg', 
                session_items_sold, comma_value(session_sales)))));
        elseif (subcmd == 'debug') then
            print(chat.header('Auctioneer'):append(chat.message(string.format('Refresh state: %d, Zone: %s (%d)', 
                refresh.state, get_zone_name(), get_zone_id()))));
            if (auction_box == nil) then
                print(chat.header('Auctioneer'):append(chat.error('auction_box is NIL - open AH menu first')));
            else
                for slot = 0, AH_TOTAL_SLOTS - 1 do
                    if (auction_box[slot] ~= nil) then
                        local info = auction_box[slot];
                        local detail = info.status;
                        if (info.item) then
                            detail = detail .. ' - ' .. info.item;
                        end
                        print(chat.header('Auctioneer'):append(chat.message(string.format('  Slot %d: %s', slot + 1, detail))));
                    end
                end
            end
            print(chat.header('Auctioneer'):append(chat.message(string.format('Clear queue: %d items', #clear_queue))));
        elseif (subcmd == 'scan') then
            -- Debug: scan and list all nearby named entities
            local entity = AshitaCore:GetMemoryManager():GetEntity();
            local player_pos = get_player_position();
            print(chat.header('Auctioneer'):append(chat.message('Scanning nearby entities...')));
            local count = 0;
            for i = 1, 2048 do
                local render_flags = entity:GetRenderFlags0(i);
                if (render_flags ~= 0 and render_flags ~= nil) then
                    local name = entity:GetName(i);
                    if (name ~= nil and name ~= '') then
                        local npc_x = entity:GetLocalPositionX(i);
                        local npc_z = entity:GetLocalPositionZ(i);
                        local dist = distance_to(player_pos, { x = npc_x, z = npc_z });
                        if (dist < 15) then
                            local spawn = entity:GetSpawnFlags(i);
                            print(chat.message(string.format('  [%d] %s (%.1fy) spawn=0x%X', i, name, dist, spawn)));
                            count = count + 1;
                            if (count >= 15) then
                                print(chat.message('  ... (truncated)'));
                                break;
                            end
                        end
                    end
                end
            end
        elseif (subcmd == 'help') then
            print(chat.header('Auctioneer'):append(chat.message('Commands:')));
            print(chat.message('  /ah - Toggle window'));
            print(chat.message('  /ah refresh - Refresh all slots'));
            print(chat.message('  /ah menu - Open AH menu'));
            print(chat.message('  /ah clear - Clear sold/expired'));
            print(chat.message('  /ah stats - Session sales'));
            print(chat.message('  /ah debug - Debug info'));
            print(chat.message('  /sell <item> <single|stack> <price>'));
            print(chat.message('  /buy <item> <single|stack> <price>'));
        end
        return;
    end
    
    -- Buy/Sell commands
    if (cmd == '/sell' or cmd == '/buy') then
        if (not is_in_ah_zone()) then
            print(chat.header('Auctioneer'):append(chat.error('Not in an AH zone.')));
            return;
        end
        if (lclock >= now) then
            print(chat.header('Auctioneer'):append(chat.warning('Please wait...')));
            return;
        end
        if (#args < 4) then
            print(chat.header('Auctioneer'):append(chat.message('Usage: /' .. cmd:sub(2) .. ' <item> <single|stack> <price>')));
            return;
        end
        
        local item_name_arg = table.concat(args, ' ', 2, #args - 2);
        local vol = args[#args - 1];
        local price = args[#args];
        
        if (ah_proposal(cmd:sub(2), item_name_arg, vol, price)) then
            lclock = now + 3;
        end
    end
end);

ashita.events.register('load', 'auctioneer_load', function()
    print(chat.header('Auctioneer'):append(chat.message('v4.0 Loaded. /ah help for commands.')));
end);

ashita.events.register('unload', 'auctioneer_unload', function()
    pcall(settings.save);
end);
