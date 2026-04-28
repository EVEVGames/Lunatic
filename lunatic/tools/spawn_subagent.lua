-- lunatic/tools/spawn_subagent.lua
-- Tool: spawn_subagent. Placeholder.
--
-- The agent loop intercepts tool calls named "spawn_subagent" and routes
-- them directly to the SubagentManager — see lunatic/loop.lua. This file
-- exists only so the registry has a module path to reference.

local args, ctx = ...
return nil, "spawn_subagent must be invoked through Lunatic's subagent manager"
