-- Registry of view descriptors for the org dashboard right pane.
-- Each descriptor defines how to fetch, render, and act on a view.
-- Adding a new view is just adding an entry to this array.

local org_view = require("sf.ui.org_view")

local views = {
  {
    id = "details",
    key = "d",
    label = "Details",
    fetch = function(record, callback)
      org_view.fetch_org_display(record, callback)
    end,
    render = function(record, data)
      return org_view.render_detail_lines(record, nil, data, nil)
    end,
    action = nil, -- details view is fetch+render only
  },
}

return views
