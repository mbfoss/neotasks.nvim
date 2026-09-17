---@class tomltools.Tree.Item
---@field id any
---@field data any

---@class tomltools.Tree.ItemUpdate
---@field id any
---@field data any
---@field keep_children boolean

---@class tomltools.Tree.Node
---@field parent_id any|nil
---@field data any
---@field first_child any|nil
---@field last_child any|nil
---@field next_sibling any|nil
---@field prev_sibling any|nil

---@class tomltools.Tree.FlatNode
---@field id any
---@field data any
---@field depth integer

---@generic T
---@class tomltools.Tree
---@field _nodes table<any, tomltools.Tree.Node>
---@field _root_first any|nil
---@field _root_last any|nil
local Tree = {}
Tree.__index = Tree

function Tree.new()
	local obj = setmetatable({}, Tree)
	obj:_init()
	return obj
end

---@private
function Tree:_init()
	---@type table<any, tomltools.Tree.Node>
	self._nodes = {}

	---@type any|nil
	self._root_first = nil

	---@type any|nil
	self._root_last = nil
end

---@private
---@param parent_id any|nil
---@param id any
function Tree:_link_child(parent_id, id)
	local parent = parent_id and self._nodes[parent_id]
	if not parent then
		if not self._root_first then
			self._root_first = id
			self._root_last = id
		else
			local last = self._root_last
			self._nodes[last].next_sibling = id
			self._nodes[id].prev_sibling = last
			self._root_last = id
		end
		return
	end
	if not parent.first_child then
		parent.first_child = id
		parent.last_child = id
	else
		local last = parent.last_child
		self._nodes[last].next_sibling = id
		self._nodes[id].prev_sibling = last
		parent.last_child = id
	end
end

---@private
---@param reference_id any
---@param id any
---@param before boolean true to insert before, false to insert after
function Tree:_link_sibling(reference_id, id, before)
	local ref_node = self._nodes[reference_id]
	assert(ref_node, "reference_id does not exist")

	local parent_id = ref_node.parent_id

	local node = self._nodes[id]
	assert(node, "node must exist before linking")

	if before then
		if parent_id == nil then
			if reference_id == self._root_first then
				node.prev_sibling = nil
				node.next_sibling = reference_id
				ref_node.prev_sibling = id
				self._root_first = id
			else
				local prev_ref = ref_node.prev_sibling
				node.prev_sibling = prev_ref
				node.next_sibling = reference_id
				ref_node.prev_sibling = id
				if prev_ref then
					self._nodes[prev_ref].next_sibling = id
				end
			end
		else
			local parent = self._nodes[parent_id]
			if reference_id == parent.first_child then
				node.prev_sibling = nil
				node.next_sibling = reference_id
				ref_node.prev_sibling = id
				parent.first_child = id
			else
				local prev_ref = ref_node.prev_sibling
				node.prev_sibling = prev_ref
				node.next_sibling = reference_id
				ref_node.prev_sibling = id
				if prev_ref then
					self._nodes[prev_ref].next_sibling = id
				end
			end
		end
	else
		if parent_id == nil then
			if reference_id == self._root_last then
				node.prev_sibling = reference_id
				node.next_sibling = nil
				ref_node.next_sibling = id
				self._root_last = id
			else
				local next_ref = ref_node.next_sibling
				node.prev_sibling = reference_id
				node.next_sibling = next_ref
				ref_node.next_sibling = id
				if next_ref then
					self._nodes[next_ref].prev_sibling = id
				end
			end
		else
			local parent = self._nodes[parent_id]
			if reference_id == parent.last_child then
				node.prev_sibling = reference_id
				node.next_sibling = nil
				ref_node.next_sibling = id
				parent.last_child = id
			else
				local next_ref = ref_node.next_sibling
				node.prev_sibling = reference_id
				node.next_sibling = next_ref
				ref_node.next_sibling = id
				if next_ref then
					self._nodes[next_ref].prev_sibling = id
				end
			end
		end
	end
end

function Tree:_unlink(id)
	local node = self._nodes[id]
	if not node then return end

	local parent_id = node.parent_id
	local prev = node.prev_sibling
	local next = node.next_sibling
	if parent_id == nil then
		if id == self._root_first then self._root_first = next end
		if id == self._root_last then self._root_last = prev end
	else
		local parent = self._nodes[parent_id]
		if parent then
			if id == parent.first_child then parent.first_child = next end
			if id == parent.last_child then parent.last_child = prev end
		end
	end
	if prev then
		local prev_node = self._nodes[prev]
		if prev_node then
			prev_node.next_sibling = next
		end
	end
	if next then
		local next_node = self._nodes[next]
		if next_node then
			next_node.prev_sibling = prev
		end
	end
	node.prev_sibling = nil
	node.next_sibling = nil
end

---@private
---@param id any
function Tree:_remove_subtree(id)
	local node = self._nodes[id]
	if not node then return end

	local child = node.first_child
	while child do
		local next_child = self._nodes[child].next_sibling
		self:_remove_subtree(child)
		child = next_child
	end

	self:_unlink(id)
	self._nodes[id] = nil
end

---@generic T
---@param parent_id any|nil
---@param items tomltools.Tree.Item[]
function Tree:set_children(parent_id, items)
	assert(type(items) == "table")
	local parent_node = parent_id and self._nodes[parent_id]
	assert(not parent_id or parent_node, "parent does not exist")
	do
		local child
		if parent_node then
			child = parent_node.first_child
		else
			child = self._root_first
		end
		while child do
			local next_child = self._nodes[child].next_sibling
			self:_remove_subtree(child)
			child = next_child
		end

		if parent_node then
			parent_node.first_child = nil
			parent_node.last_child  = nil
		else
			self._root_first = nil
			self._root_last  = nil
		end
	end
	local first_new = nil
	local last_new  = nil

	for _, item in ipairs(items) do
		local id = assert(item.id, "item must have .id")
		assert(self._nodes[id] == nil, ("duplicate id: %s"):format(tostring(id)))

		local node = {
			parent_id    = parent_id,
			data         = item.data,
			first_child  = nil,
			last_child   = nil,
			next_sibling = nil,
			prev_sibling = nil,
		}
		self._nodes[id] = node

		node.prev_sibling = last_new
		if last_new then
			self._nodes[last_new].next_sibling = id
		end
		if not first_new then first_new = id end
		last_new = id
	end
	if parent_node then
		parent_node.first_child = first_new
		parent_node.last_child  = last_new
	else
		self._root_first = first_new
		self._root_last  = last_new
	end
end

---@param parent_id any|nil
---@param items tomltools.Tree.ItemUpdate[]
function Tree:update_children(parent_id, items)
	assert(type(items) == "table", "items must be a table")
	local parent_node = parent_id and self._nodes[parent_id]
	assert(not parent_id or parent_node, "parent does not exist")
	local keep_ids = {}
	for _, item in ipairs(items) do
		assert(not keep_ids[item.id], "duplicate item id in provided items: " .. tostring(item.id))
		keep_ids[item.id] = true
	end
	local current_id
	if parent_id then
		current_id = parent_node and parent_node.first_child or nil
	else
		current_id = self._root_first
	end
	while current_id do
		local next_id = self._nodes[current_id].next_sibling
		if not keep_ids[current_id] then
			self:_remove_subtree(current_id)
		end
		current_id = next_id
	end
	local first_new = nil
	local last_new  = nil

	for _, item in ipairs(items) do
		local id = assert(item.id, "item must have .id")
		local node = self._nodes[id]

		if node then
			assert(node.parent_id == parent_id,
				string.format("ID conflict: node '%s' already exists under parent '%s'",
					tostring(id), tostring(node.parent_id)))

			if item.keep_children == false then
				self:_remove_children(node)
			end
			node.data = item.data
			node.prev_sibling = last_new
			node.next_sibling = nil
		else
			node = {
				parent_id    = parent_id,
				data         = item.data,
				first_child  = nil,
				last_child   = nil,
				next_sibling = nil,
				prev_sibling = last_new,
			}
			self._nodes[id] = node
		end
		if last_new then
			self._nodes[last_new].next_sibling = id
		end

		if not first_new then first_new = id end
		last_new = id
	end
	if parent_id then
		parent_node.first_child = first_new
		parent_node.last_child  = last_new
	else
		self._root_first = first_new
		self._root_last  = last_new
	end
end

---@generic T
---@param parent_id any|nil
---@param id any
---@param data T
function Tree:add_item(parent_id, id, data)
	assert(id ~= nil, "id is required")
	assert(parent_id == nil or self._nodes[parent_id], "parent does not exist")

	local node = self._nodes[id]
	assert(not node, "id already exists " .. tostring(id))
	node = {
		parent_id    = parent_id,
		data         = data,
		first_child  = nil,
		last_child   = nil,
		next_sibling = nil,
		prev_sibling = nil,
	}
	self._nodes[id] = node
	self:_link_child(parent_id, id)
end

---@generic T
---@param id any
---@param data any
---@return boolean
function Tree:set_item_data(id, data)
	assert(id ~= nil, "id is required")
	local node = self._nodes[id]
	if not node then return false end
	node.data = data
	return true
end

---@generic T
---@param reference_id any
---@param id any
---@param data T
---@param before boolean true to insert before sibling, false to insert after
function Tree:add_sibling(reference_id, id, data, before)
	assert(id ~= nil, "id is required")
	assert(reference_id ~= nil, "reference_id is required")

	local ref_node = self._nodes[reference_id]
	assert(ref_node, "reference_id does not exist")

	local parent_id = ref_node.parent_id

	local node = self._nodes[id]
	assert(not node, "id already exists " .. tostring(id))
	node = {
		parent_id    = parent_id,
		data         = data,
		first_child  = nil,
		last_child   = nil,
		next_sibling = nil,
		prev_sibling = nil,
	}
	self._nodes[id] = node
	self:_link_sibling(reference_id, id, before)
end

---@param id any
---@return boolean
function Tree:have_item(id)
	assert(id, "id required")
	return self._nodes[id] ~= nil
end

---@return boolean
function Tree:is_root(id)
	local node = self._nodes[id]
	return node ~= nil and node.parent_id == nil
end

---@return tomltools.Tree.Item[]
function Tree:get_roots()
	local items = {}
	local child_id = self._root_first
	while child_id do
		local node = self._nodes[child_id]
		table.insert(items, {
			id = child_id,
			data = node.data,
		})
		child_id = node.next_sibling
	end

	return items
end

---@return fun(): (any, any) -- iterator yielding (id, data) for each root
function Tree:iter_roots()
	local id = self._root_first
	local nodes = self._nodes
	return function()
		if id == nil then return nil end
		local node = nodes[id]
		local current_id = id
		id = node.next_sibling
		return current_id, node.data
	end
end

---@param id any
---@return any|nil parent_id
function Tree:get_parent_id(id)
	assert(id ~= nil, "id is required")
	local node = self._nodes[id]
	if not node then
		error("node does not exist")
	end
	return node.parent_id
end

---@param id any
---@return any -- node data or nil
function Tree:get_data(id)
	assert(id, "id required")
	local node = self._nodes[id]
	return node and node.data or nil
end

---@param id any
---@return integer
function Tree:get_depth(id)
	if not id then return 0 end

	local node = self._nodes[id]
	if not node then
		error("node does not exist: " .. tostring(id))
	end

	local depth = 0
	local current_parent = node.parent_id

	while current_parent ~= nil do
		depth = depth + 1
		local parent_node = self._nodes[current_parent]
		if not parent_node then break end
		current_parent = parent_node.parent_id
	end

	return depth
end

---@return tomltools.Tree.Item[]
function Tree:get_items()
	local items = {}
	for id, node in pairs(self._nodes) do
		table.insert(items, { id = id, data = node.data })
	end
	return items
end

---@param id any
---@return boolean
function Tree:have_children(id)
	assert(id, "id required")
	local node = self._nodes[id]
	return node ~= nil and node.first_child ~= nil
end

---@param parent_id any|nil If nil, returns root nodes.
---@return any[]
function Tree:get_children_ids(parent_id)
	assert(parent_id, "id required")
	local parent_node = self._nodes[parent_id]
	assert(parent_node, "parent does not exist")
	local ids = {}
	local child_id = parent_node.first_child
	while child_id do
		table.insert(ids, child_id)
		local node = self._nodes[child_id]
		child_id = node.next_sibling
	end
	return ids
end

---@param parent_id any|nil If nil, returns root nodes.
---@return tomltools.Tree.Item[]
function Tree:get_children(parent_id)
	assert(parent_id, "id required")

	local parent_node = self._nodes[parent_id]
	assert(parent_node, "parent does not exist")

	local items = {}
	local child_id

	child_id = parent_node.first_child
	while child_id do
		local node = self._nodes[child_id]
		table.insert(items, { id = child_id, data = node.data })
		child_id = node.next_sibling
	end

	return items
end

---@param id any
---@return any|nil
function Tree:get_first_child_id(id)
	assert(id, "id required")
	local node = self._nodes[id]
	return node and node.first_child or nil
end

---@param id any
---@return any|nil
function Tree:get_last_child_id(id)
	assert(id, "id required")
	local node = self._nodes[id]
	return node and node.last_child or nil
end

---@param id any
---@return any|nil
function Tree:get_prev_sibling_id(id)
	assert(id, "id required")
	local node = self._nodes[id]
	return node and node.prev_sibling or nil
end

---@param id any
---@return any|nil
function Tree:get_next_sibling_id(id)
	assert(id, "id required")
	local node = self._nodes[id]
	return node and node.next_sibling or nil
end

---@param parent_id any
---@return fun(): (any, any) -- iterator yielding (id, data) for each child
function Tree:iter_children(parent_id)
	assert(parent_id, "id required")
	local parent_node = self._nodes[parent_id]
	assert(parent_node, "parent does not exist")
	local id = parent_node.first_child
	local nodes = self._nodes
	return function()
		if id == nil then return nil end
		local node = nodes[id]
		local current_id = id
		id = node.next_sibling
		return current_id, node.data
	end
end

---@param id any
function Tree:remove_item(id)
	assert(id, "id required")
	self:_remove_subtree(id)
end

---@private
---@param node tomltools.Tree.Node
function Tree:_remove_children(node)
	local child = node.first_child
	while child do
		local next_child = self._nodes[child].next_sibling
		self:_remove_subtree(child)
		child = next_child
	end
	node.first_child = nil
	node.last_child = nil
end

---@param id any
function Tree:remove_children(id)
	assert(id ~= nil, "id is required")
	local node = self._nodes[id]
	if not node then return end
	self:_remove_children(node)
end

---@private
---@param id any
---@param depth integer
---@param handler fun(id:any, data:any, depth:number):boolean?
function Tree:_walk_node(id, depth, handler)
	local node = self._nodes[id]
	if not node then return end

	if not handler(id, node.data, depth) then
		return
	end

	local child = node.first_child
	while child do
		self:_walk_node(child, depth + 1, handler)
		child = self._nodes[child].next_sibling
	end
end

---@param handler fun(id:any, data:any, depth:number):boolean?
function Tree:walk_tree(handler)
	local id = self._root_first
	while id do
		self:_walk_node(id, 0, handler)
		id = self._nodes[id].next_sibling
	end
end

---@param id any
---@param handler fun(id:any, data:any, depth:number):boolean?
function Tree:walk_node(id, handler)
	assert(id ~= nil, "id is required")
	assert(self._nodes[id], "node does not exist")
	self:_walk_node(id, 0, handler)
end

function Tree:validate()
	local visited = {}
	local function assertf(cond, fmt, ...)
		if not cond then
			error("Tree:validate() - " .. string.format(fmt, ...))
		end
	end

	local function validate_root_chain()
		local id = self._root_first
		local prev = nil
		local count = 0

		while id do
			count = count + 1
			local node = self._nodes[id]
			assertf(node, "Root node %s missing from _nodes", tostring(id))
			assertf(node.parent_id == nil,
				"Root node %s has non-nil parent_id %s",
				tostring(id), tostring(node.parent_id))

			assertf(node.prev_sibling == prev,
				"Root node %s has incorrect prev_sibling",
				tostring(id))

			if prev then
				assertf(self._nodes[prev].next_sibling == id,
					"Broken root sibling link: %s -> %s",
					tostring(prev), tostring(id))
			end

			prev = id
			id = node.next_sibling
		end

		assertf(prev == self._root_last,
			"_root_last mismatch: expected %s, got %s",
			tostring(prev), tostring(self._root_last))
	end
	local function walk(id)
		assertf(not visited[id],
			"Cycle or multiple-parent detected at node %s",
			tostring(id))

		visited[id] = true

		local node = self._nodes[id]
		assertf(node, "Node %s missing from _nodes", tostring(id))
		local child = node.first_child
		local prev = nil

		if not child then
			assertf(node.last_child == nil,
				"Node %s has nil first_child but non-nil last_child",
				tostring(id))
		end

		while child do
			local child_node = self._nodes[child]
			assertf(child_node,
				"Child %s of parent %s missing from _nodes",
				tostring(child), tostring(id))

			assertf(child_node.parent_id == id,
				"Child %s has wrong parent_id %s (expected %s)",
				tostring(child),
				tostring(child_node.parent_id),
				tostring(id))

			assertf(child_node.prev_sibling == prev,
				"Child %s has incorrect prev_sibling",
				tostring(child))

			if prev then
				assertf(self._nodes[prev].next_sibling == child,
					"Broken sibling link: %s -> %s",
					tostring(prev), tostring(child))
			end

			prev = child
			walk(child)

			child = child_node.next_sibling
		end

		assertf(prev == node.last_child,
			"Node %s last_child mismatch (expected %s, got %s)",
			tostring(id),
			tostring(prev),
			tostring(node.last_child))
	end
	validate_root_chain()
	local id = self._root_first
	while id do
		walk(id)
		id = self._nodes[id].next_sibling
	end
	for id, _ in pairs(self._nodes) do
		assertf(visited[id],
			"Node %s exists in _nodes but is not reachable from any root",
			tostring(id))
	end

	return true
end

return Tree
