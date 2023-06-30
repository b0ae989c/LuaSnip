local util = require("luasnip.util.util")
local ext_util = require("luasnip.util.ext_opts")
local types = require("luasnip.util.types")
local key_indexer = require("luasnip.nodes.key_indexer")

local function subsnip_init_children(parent, children)
	for _, child in ipairs(children) do
		if child.type == types.snippetNode then
			child.snippet = parent.snippet
			child:resolve_child_ext_opts()
		end
		child:resolve_node_ext_opts()
		child:subsnip_init()
	end
end

local function init_child_positions_func(
	key,
	node_children_key,
	child_func_name
)
	-- maybe via load()?
	return function(node, position_so_far)
		node[key] = vim.deepcopy(position_so_far)
		local pos_depth = #position_so_far + 1

		for indx, child in ipairs(node[node_children_key]) do
			position_so_far[pos_depth] = indx
			child[child_func_name](child, position_so_far)
		end
		-- undo changes to position_so_far.
		position_so_far[pos_depth] = nil
	end
end

local function make_args_absolute(args, parent_insert_position, target)
	for i, arg in ipairs(args) do
		if type(arg) == "number" then
			-- the arg is a number, should be interpreted relative to direct
			-- parent.
			local t = vim.deepcopy(parent_insert_position)
			table.insert(t, arg)
			target[i] = { absolute_insert_position = t }
		else
			-- insert node, absolute_indexer, or key itself, node's
			-- absolute_insert_position may be nil, check for that during
			-- usage.
			target[i] = arg
		end
	end
end

local function wrap_args(args)
	-- stylua: ignore
	if type(args) ~= "table" or
	  (type(args) == "table" and args.absolute_insert_position) or
	  key_indexer.is_key(args) then
		-- args is one single arg, wrap it.
		return { args }
	else
		return args
	end
end

local function get_nodes_between(parent, child_pos)
	local nodes = {}

	local indx = #parent.absolute_position + 1
	local prev = parent
	while child_pos[indx] do
		local next = prev:resolve_position(child_pos[indx])
		nodes[#nodes + 1] = next
		prev = next
		indx = indx + 1
	end

	return nodes
end

local function leave_nodes_between(parent, child, no_move)
	local nodes = get_nodes_between(parent, child.absolute_position)
	if #nodes == 0 then
		return
	end

	-- reverse order, leave child first.
	for i = #nodes, 2, -1 do
		-- this only happens for nodes where the parent will also be left
		-- entirely (because we stop at nodes[2], and handle nodes[1]
		-- separately)
		nodes[i]:input_leave(no_move)
		nodes[i-1]:input_leave_children()
	end
	nodes[1]:input_leave(no_move)
end

local function enter_nodes_between(parent, child, no_move)
	local nodes = get_nodes_between(parent, child.absolute_position)
	if #nodes == 0 then
		return
	end

	for i = 1, #nodes-1 do
		-- only enter children for nodes before the last (lowest) one.
		nodes[i]:input_enter(no_move)
		nodes[i]:input_enter_children()
	end
	nodes[#nodes]:input_enter(no_move)
end

local function select_node(node)
	local node_begin, node_end = node.mark:pos_begin_end_raw()
	util.any_select(node_begin, node_end)
end

local function print_dict(dict)
	print(vim.inspect(dict, {
		process = function(item, path)
			if path[#path] == "node" or path[#path] == "dependent" then
				return "node@" .. vim.inspect(item.absolute_position)
			elseif path[#path] ~= vim.inspect.METATABLE then
				return item
			end
		end,
	}))
end

local function init_node_opts(opts)
	local in_node = {}
	if not opts then
		opts = {}
	end

	-- copy once here, the opts might be reused.
	in_node.node_ext_opts =
		ext_util.complete(vim.deepcopy(opts.node_ext_opts or {}))

	if opts.merge_node_ext_opts == nil then
		in_node.merge_node_ext_opts = true
	else
		in_node.merge_node_ext_opts = opts.merge_node_ext_opts
	end

	in_node.key = opts.key

	return in_node
end

local function snippet_extend_context(arg, extend)
	if type(arg) == "string" then
		arg = { trig = arg }
	end

	-- both are table or nil now.
	return vim.tbl_extend("keep", arg or {}, extend or {})
end

local function wrap_context(context)
	if type(context) == "string" then
		return { trig = context }
	else
		return context
	end
end

local cmp_functions = {
	rgrav_less = function(pos, range_from)
		return util.pos_cmp(pos, range_from) < 0
	end,
	rgrav_greater = function(pos, range_to)
		return util.pos_cmp(pos, range_to) >= 0
	end,
	boundary_outside_less = function(pos, range_from)
		return util.pos_cmp(pos, range_from) <= 0
	end,
	boundary_outside_greater = function(pos, range_to)
		return util.pos_cmp(pos, range_to) >= 0
	end
}
-- `nodes` is a list of nodes ordered by their occurrence in the buffer.
-- `pos` is a row-column-tuble, byte-columns, and we return the node the LEFT
-- EDGE(/side) of `pos` is inside.
-- This convention is chosen since a snippet inserted at `pos` will move the
-- character at `pos` to the right.
-- The exact meaning of "inside" can be influenced with `respect_rgravs`:
-- * if it is true, "inside" is replicated to match the shifting-behaviour of
--   extmarks:
--   First of all, we compare the left edge of `pos` with the left/right edges
--   of from/to, depending on rgrav.
--   If the left edge is <= left/right edge of from, and < left/right edge of
--   to, `pos` is inside the node.
--
-- * if it is false, pos has to be fully inside a node to be considered inside
--   it. If pos is on the left endpoint, it is considered to be left of the
--   node, and likewise for the right endpoint.
-- 
-- This differentiation is useful for making this function more general:
-- When searching in the contiguous nodes of a snippet, we'd like this routine
-- to return any of them (obviously the one pos is inside/or on the border of),
-- but in no case fail.
-- However! when searching the top-level snippets with the intention of finding
-- the snippet/node a new snippet should be expanded inside, it seems better to
-- shift an existing snippet to the right/left than expand the new snippet
-- inside it (when the expand-point is on the boundary).
local function binarysearch_pos(nodes, pos, respect_rgravs)
	local left = 1
	local right = #nodes

	local less, greater
	if respect_rgravs then
		less = cmp_functions.rgrav_less
		greater = cmp_functions.rgrav_greater
	else
		less = cmp_functions.boundary_outside_less
		greater = cmp_functions.boundary_outside_greater
	end

	-- actual search-routine from
	-- https://github.com/Roblox/Wiki-Lua-Libraries/blob/master/StandardLibraries/BinarySearch.lua
	if #nodes == 0 then
		return nil, 1
	end
	while true do
		local mid = left + math.floor((right-left)/2)
		local mid_mark = nodes[mid].mark
		local mid_from, mid_to = mid_mark:pos_begin_end_raw()

		if respect_rgravs then
			-- if rgrav is set on either endpoint, the node considers its
			-- endpoint to be the right, not the left edge.
			-- We only want to work with left edges but since the right edge is
			-- the left edge of the next column, this is not an issue :)
			-- TODO: does this fail with multibyte characters???
			if mid_mark:get_rgrav(-1) then
				mid_from[2] = mid_from[2] + 1
			end
			if mid_mark:get_rgrav(1) then
				mid_to[2] = mid_to[2] + 1
			end
		end
		if greater(pos, mid_to) then
			-- make sure right-left becomes smaller.
			left = mid + 1
			if left > right then
				return nil, mid + 1
			end
		elseif less(pos, mid_from) then
			-- continue search on left side
			right = mid - 1
			if left > right then
				return nil, mid
			end
		else
			-- greater-equal than mid_from, smaller or equal to mid_to => left edge
			-- of pos is inside nodes[mid] :)
			return nodes[mid], mid
		end
	end
end

return {
	subsnip_init_children = subsnip_init_children,
	init_child_positions_func = init_child_positions_func,
	make_args_absolute = make_args_absolute,
	wrap_args = wrap_args,
	wrap_context = wrap_context,
	get_nodes_between = get_nodes_between,
	leave_nodes_between = leave_nodes_between,
	enter_nodes_between = enter_nodes_between,
	select_node = select_node,
	print_dict = print_dict,
	init_node_opts = init_node_opts,
	snippet_extend_context = snippet_extend_context,
	binarysearch_pos = binarysearch_pos,
}
