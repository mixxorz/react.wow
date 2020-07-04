local AceGUI = LibStub("AceGUI-3.0")
local lodash = LibStub("lodash.wow")

local MAJOR, MINOR = "react.wow", 1
local React = LibStub:NewLibrary(MAJOR, MINOR)

if not React then return end -- No Upgrade needed.

local _print = print

local assign, firstToUpper, forEach, get = lodash.assign, lodash.firstToUpper, lodash.forEach, lodash.get
local includes, keys = lodash.includes, lodash.keys
local push, print, startsWith = lodash.push, lodash.print, lodash.startsWith
local isFunction, isNumber, isString = lodash.isFunction, lodash.isNumber, lodash.isString

local nextUnitOfWork = nil
local currentRoot = nil
local wipRoot = nil
local deletions = nil

local wipFiber = nil
local hookIndex = nil

local fiberDebug = function (fiber)
  if fiber == nil then
    print('=== Nil Fiber ===')
    return
  end
  print('===', fiber.type, '===')
  print('child', get(fiber, {'child', 'type'}))
  print('sibling', get(fiber, {'sibling', 'type'}))
  print('parent', get(fiber, {'parent', 'type'}))
end

local isGone = function (key, nextProps)
  return not includes(keys(nextProps), key)
end

local isEventHandler = function (key)
  return startsWith(key, 'on')
end

local isProperty = function (key)
  return key ~= 'children' and not isEventHandler(key)
end

local deleteAttributes = function (ui, prevProps, nextProps)
  for key, value in pairs(prevProps) do
    if isProperty(key) and isGone(key, nextProps) then
      local defaultValue = nil

      -- Sane default values
      if isNumber(value) then
        defaultValue = 0
      elseif isString(value) then
        defaultValue = ''
      end

      ui['Set'..firstToUpper(key)](ui, defaultValue)
    elseif isEventHandler(key) and isGone(key, nextProps) then
      -- Set noop. No way to remove event handler in AceGUI
      ui:SetCallback(firstToUpper(key), function () return end)
    end
  end
end

local setAttributes = function (ui, props)
  for key, value in pairs(props) do
    if isProperty(key) then
      if not pcall(function () ui['Set'..firstToUpper(key)](ui, value) end) then
        print('Unable to set property "'..key..'" on '..ui.frame:GetObjectType())
      end
    elseif isEventHandler(key) then
      ui:SetCallback(firstToUpper(key), value)
    end
  end
end

local updateUi = function (ui, prevProps, nextProps)
  -- Reset old properties to defaults
  deleteAttributes(ui, prevProps, nextProps)

  -- Add or update attributes and event handlers
  setAttributes(ui, nextProps)
end

local createUi = function (fiber)
  local ui = AceGUI:Create(fiber.type)

  updateUi(ui, {}, fiber.props)
  return ui
end

local function reconcileChildren (fiber, elements)
  local index = 1
  local prevSibling
  local oldFiber = get(fiber, {'alternate', 'child'})

  -- Build fiber tree
  -- Iterate over oldFiber linked list and elements array simultaneously
  while index < #elements + 1 or oldFiber ~= nil do
    -- element is what we want to render
    -- oldFiber is its previous incarnation
    local element = elements[index]
    local newFiber = nil

    local sameType = get(oldFiber, {'type'}) == get(element, {'type'})

    if sameType then
      -- Re-use existing UI object
      newFiber = {
        type = oldFiber.type,
        props = element.props,
        ui = oldFiber.ui,
        parent = fiber,
        alternate = oldFiber,
        effectTag = "UPDATE"
      }
    elseif element and not sameType then
      -- Add node
      newFiber = {
        type = element.type,
        props = element.props,
        ui = nil,
        parent = fiber,
        alternate = nil,
        effectTag = "PLACEMENT"
      }
    elseif oldFiber and not sameType then
      -- Delete the old node
      oldFiber.effectTag = "DELETION"
      push(deletions, oldFiber)
    end

    if oldFiber ~= nil then
      oldFiber = oldFiber.sibling
    end

    if index == 1 then
      fiber.child = newFiber
    elseif element ~= nil then
      prevSibling.sibling = newFiber
    end

    prevSibling = newFiber
    index = index + 1
  end
end

local function updateFunctionComponent (fiber)
  wipFiber = fiber
  hookIndex = 1
  wipFiber.hooks = {}

  local children = {fiber.type(fiber.props)}
  reconcileChildren(fiber, children)
end

local function updateHostComponent (fiber)
  if fiber.ui == nil then
    fiber.ui = createUi(fiber)
  end

  reconcileChildren(fiber, fiber.props.children)
end

local function performUnitOfWork (fiber)
  if isFunction(fiber.type) then
    updateFunctionComponent(fiber)
  else
    updateHostComponent(fiber)
  end

  -- Find next unit of work
  -- Start with child
  if fiber.child then
    return fiber.child
  end

  local nextFiber = fiber

  while nextFiber do
    -- Then sibling
    if nextFiber.sibling then
      return nextFiber.sibling
    end

    -- Then uncle
    nextFiber = nextFiber.parent
  end

  -- Reached the root
end

local function commitDeletion (fiber)
  -- Find child UI object
  if fiber.ui ~= nil then
    AceGUI:Release(fiber.ui)
  else
    commitDeletion(fiber.child)
  end
end

local function commitWork (fiber)
  if fiber == nil then
    return
  end

  -- Find a parent UI object
  local uiParentFiber = fiber.parent
  while (uiParentFiber.ui == nil) do
    uiParentFiber = uiParentFiber.parent
  end

  local uiParent = uiParentFiber.ui

  if fiber.effectTag == "PLACEMENT" and fiber.ui ~= nil then
    uiParent:AddChild(fiber.ui)
  elseif fiber.effectTag == "UPDATE" and fiber.ui ~= nil then
    updateUi(fiber.ui, fiber.alternate.props, fiber.props)
  elseif fiber.effectTag == "DELETION" then
    commitDeletion(fiber)
  end

  commitWork(fiber.child)
  commitWork(fiber.sibling)
end

local commitRoot = function ()
  forEach(deletions, commitWork)
  commitWork(wipRoot.child)
  currentRoot = wipRoot
  wipRoot = nil
end

local workLoop = function ()
  if nextUnitOfWork ~= nil then
    nextUnitOfWork = performUnitOfWork(nextUnitOfWork)
  end

  if nextUnitOfWork == nil and wipRoot then
    -- Commit changes to UI when the entire fiber tree has been built
    commitRoot()
  end
end

function React.useEffect (callback, deps)
  local hook = {
    deps = deps,
  }

  -- Get value from previous fiber
  local oldHook = get(wipFiber, {'alternate', 'hooks', hookIndex})

  local hasChangedDeps = false

  if oldHook == nil or hook.deps == nil then
    -- If there is no oldHook, it's rendering for the first time
    -- If hook.deps is nil, run callback every render
    hasChangedDeps = true
  elseif #hook.deps ~= #oldHook.deps then
    print('You are not allowed to change the number of dependencies to useEffect')
  else
    -- Otherwise, check for any changes in the dependencies
    local index = 1

    while index < #hook.deps + 1 do
      if oldHook.deps[index] ~= hook.deps[index] then
        hasChangedDeps = true
        break
      end

      index = index + 1
    end
  end

  if hasChangedDeps then
    callback()
  end

  push(wipFiber.hooks, hook)
  hookIndex = hookIndex + 1
end

function React.useState (initial)
  local hook = {
    state = initial,
    queue = {}
  }

  -- Get value from previous fiber
  local oldHook = get(wipFiber, {'alternate', 'hooks', hookIndex})

  if oldHook ~= nil then
    hook.state = oldHook.state
  end

  -- Update state based on previous action
  local actions = get(oldHook, {'queue'}, {}) or {}
  for _, action  in ipairs(actions) do
    hook.state = action(hook.state)
  end

  local setState = function (action)
    push(hook.queue, action)

    -- Trigger a re-render
    wipRoot = {
      ui = currentRoot.ui,
      props = currentRoot.props,
      alternate = currentRoot
    }
    nextUnitOfWork = wipRoot
    deletions = {}
  end

  push(wipFiber.hooks, hook)
  hookIndex = hookIndex + 1

  return hook.state, setState
end

function React.createElement (type, props, ...)
  local children = {...}

  local ret = {
    type = type,
    props = assign({}, props, {children = children}),
  }
  return ret
end

function React.render (element, container)
  wipRoot = {
    ui = container,
    props = {
      children = {element}
    },
    alternate = currentRoot
  }
  deletions = {}
  nextUnitOfWork = wipRoot
end

-- Renderer
local reactFrame = CreateFrame("Frame", nil, UIParent)
reactFrame:SetScript("OnUpdate", workLoop)
-- handle = C_Timer.NewTicker(0.16, workLoop)
