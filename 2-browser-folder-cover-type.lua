local logger = require("logger")
local util = require("util")

logger.info("Starting ptutil patch")

-- Add the plugin directory to package.path
local plugin_path = "./plugins/projecttitle.koplugin/?.lua"
if not package.path:find(plugin_path, 1, true) then
    package.path = plugin_path .. ";" .. package.path
end

-- Now try to require ptutil
local success, ptutil = pcall(require, "ptutil")

if not success then
    logger.warn("Failed to load ptutil:", ptutil)
    return
end

logger.info("ptutil loaded successfully")

local BookInfoManager = require("bookinfomanager")
local ImageWidget = require("ui/widget/imagewidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local HorizontalSpan = require("ui/widget/horizontalspan")
local OverlapGroup = require("ui/widget/overlapgroup")
local Blitbuffer = require("ffi/blitbuffer")
local Size = require("ui/size")
local Geom = require("ui/geometry")

local original_getSubfolderCoverImages = ptutil.getSubfolderCoverImages

function ptutil.getSubfolderCoverImages(filepath, max_w, max_h)
    
    -- Query database for books in this folder with covers
    local SQ3 = require("lua-ljsqlite3/init")
    local DataStorage = require("datastorage")
    local db_conn = SQ3.open(DataStorage:getSettingsDir() .. "/PT_bookinfo_cache.sqlite3")
    db_conn:set_busy_timeout(5000)
    
    local query = string.format([[
        SELECT directory, filename FROM bookinfo
        WHERE directory = '%s/' AND has_cover = 'Y'
        ORDER BY filename ASC LIMIT 3;
    ]], filepath:gsub("'", "''"))
    
    local res = db_conn:exec(query)
    db_conn:close()
    
    if res and res[1] and res[2] and res[1][1] then
        local dir_ending = string.sub(res[1][1],-2,-2)
        local num_books = #res[1]

        -- Author folder or Series folder
        local folder_type = "Series"
        if string.sub(res[1][1],-2,-2) == "-" then folder_type = "Author" end

        -- Save all covers
        local covers = {}
        for i = 1, num_books do
            local fullpath = res[1][i] .. res[2][i]
            
            if util.fileExists(fullpath) then
                local bookinfo = BookInfoManager:getBookInfo(fullpath, true)
                if bookinfo and bookinfo.cover_bb and bookinfo.has_cover then
                    table.insert(covers, bookinfo)
                end
            end
        end

        -- Constants
        local border_total = Size.border.thin * 2
        -- Series
        local offset_x = math.floor(max_w * 0.15)  -- 15% of width to the right
        local offset_y = math.floor(max_h * 0.05)  -- 5% of height down
        -- Author (smaller)
        if folder_type == "Author" then
            offset_x = math.floor(max_w * 0.25)
            offset_y = math.floor(max_w * 0.10)
        end
        
        -- Scale all covers smaller to fit with offset
        local available_w = max_w - (#covers-1)*offset_x - border_total
        local available_h = max_h - (#covers-1)*offset_y - border_total
        -- Deal with Series, 1 book (will want a blank book showing)
        if folder_type == "Series" and #covers == 1 then
            available_w = max_w - offset_x - border_total
            available_h = max_h - offset_y - border_total
        end
        -- Deal with Author, multiple books (still want smaller books)
        if folder_type == "Author" and #covers > 1 then
            available_h = max_h - 2*offset_y - border_total
        end

        -- Make sure this isn't an empty folder
        if #covers > 0 then
            -- Now make the Individual cover widgets
            local cover_widgets = {}
            for i, bookinfo in ipairs(covers) do
                -- figure out scale factor
                local _, _, scale_factor = BookInfoManager.getCachedCoverSize(
                    bookinfo.cover_w, bookinfo.cover_h,
                    available_w, available_h
                )
                
                -- make the individual cover widget
                local cover_widget = ImageWidget:new {
                    image = bookinfo.cover_bb,
                    scale_factor = scale_factor,
                }
                local cover_size = cover_widget:getSize()
                
                table.insert(cover_widgets, {
                    widget = FrameContainer:new {
                        width = cover_size.w + border_total,
                        height = cover_size.h + border_total,
                        radius = Size.radius.default,
                        margin = 0,
                        padding = 0,
                        bordersize = Size.border.thin,
                        color = Blitbuffer.COLOR_DARK_GRAY,
                        cover_widget,
                    },
                    size = cover_size
                })
            end

            -- blank cover
            local cover_size = cover_widgets[1].size
            if folder_type == "Series" and #covers == 1 then
                -- insert a blank cover
                table.insert(cover_widgets, {
                    widget = FrameContainer:new {
                        width = cover_size.w + border_total,
                        height = cover_size.h + border_total,
                        radius = Size.radius.default,
                        margin = 0,
                        padding = 0,
                        bordersize = Size.border.thin,
                        color = Blitbuffer.COLOR_DARK_GRAY,
                        background = Blitbuffer.COLOR_LIGHT_GRAY,
                        HorizontalSpan:new { width = cover_size.w, height = cover_size.h },
                    },
                    size = cover_size
                })
            end

            -- If Author single book, return early
            if folder_type == "Author" and #covers == 1 then
                return CenterContainer:new {
                    dimen = Geom:new { w = max_w, h = max_h },
                    cover_widgets[1].widget,
                }
            end

            -- Make the overlap group widget (default is 2 books in series mode)
            -- At this point, either it was Author and orig had 1 book (returned already)
            --   or, it was Series and orig had 1 book (had a blank book inserted)
            local total_width = cover_widgets[1].size.w + border_total + (#cover_widgets-1)*offset_x
            local total_height = cover_widgets[1].size.h + border_total + (#cover_widgets-1)*offset_y
            local overlap = OverlapGroup:new {
                dimen = Geom:new { w = total_width, h = total_height },
                -- Second cover (offset down and right)
                FrameContainer:new {
                    margin = 0,
                    padding = 0,
                    padding_left = offset_x,
                    padding_top = offset_y,
                    bordersize = 0,
                    cover_widgets[2].widget,
                },
                -- Front cover (top-left)
                FrameContainer:new {
                    margin = 0,
                    padding = 0,
                    bordersize = 0,
                    cover_widgets[1].widget,
                },
            }

            -- Now for the different formats
            if folder_type == "Series" and #cover_widgets == 3 then
                -- overlap third cover
                local overlap3 = OverlapGroup:new {
                    dimen = Geom:new { w = total_width, h = total_height },
                    FrameContainer:new {
                        margin = 0,
                        padding = 0,
                        padding_left = 2*offset_x,
                        padding_top = 2*offset_y,
                        bordersize = 0,
                        cover_widgets[3].widget,
                    },
                    overlap,
                }
                overlap = overlap3
            elseif folder_type == "Author" then
                -- rewrite overlap group
                overlap = OverlapGroup:new {
                    dimen = Geom:new { w = total_width, h = total_height },
                    -- Second cover (up and right)
                    FrameContainer:new {
                        margin = 0,
                        padding = 0,
                        padding_left = offset_x,
                        padding_top = 0,
                        bordersize = 0,
                        cover_widgets[2].widget,
                    },
                    -- Front cover (middletop-left)
                    FrameContainer:new {
                        margin = 0,
                        padding = 0,
                        padding_top = offset_y,
                        bordersize = 0,
                        cover_widgets[1].widget,
                    },
                }
                if #cover_widgets == 3 then
                    -- overlap third cover
                    local overlap3 = OverlapGroup:new {
                        dimen = Geom:new { w = total_width, h = total_height },
                        FrameContainer:new {
                            margin = 0,
                            padding = 0,
                            padding_left = 2*offset_x,
                            padding_top = 2*offset_y,
                            bordersize = 0,
                            cover_widgets[3].widget,
                        },
                        overlap,
                    }
                    overlap = overlap3
                end
            end

            -- return the center container
            return CenterContainer:new {
                dimen = Geom:new { w = max_w, h = max_h },
                overlap,
            }
        end

    end
    
    -- Fallback to original mosaic behavior
    return original_getSubfolderCoverImages(filepath, max_w, max_h)
end

logger.info("Ptutil patch applied successfully")
