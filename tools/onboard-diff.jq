# What an onboarding run changed, from pohunek's own --json answers only.
# Pure: `jq -n --argjson snapshot S --argjson now N --arg own SESSION_ID -f onboard-diff.jq`.
#
#   snapshot  the record's pre-run snapshot: projects (ids), profiles
#             ({name, file_digest}), integrations (`integration status
#             --all-profiles --json` .ok), sessions ({id, group}) and agents
#             ({agent, version}); the last two are absent in a record of a tool
#             that did not take them
#   now       the same reads after the run: projects (`project list` .ok),
#             profiles (`plugin profile list --all` .ok), integrations,
#             sessions (`session list` .ok) and inspect (`host inspect local` .ok)
#   own       the onboard session's id; its own metadata is never a change
#
# Output: projects_added, profiles_created, groups_set, integrations
# ({agent, profile, hooks, skill}: what is new in that home; a skill is new only
# when no home had one at its location before the run), agent_versions
# ({agent, before, after}) and groups_known (false when the snapshot has no
# session list, so no group can be attributed to the run).

def home_key: [.agent, (.home.selector // {kind: "default"} | if .kind == "profile" then .name else null end)];
def hooks_present: (.state // "not_installed") != "not_installed";
# Skill states that mean a skill file exists (cli.md "integration status").
def skill_present: (.skill.state // "absent") | IN("current", "stale", "modified", "foreign", "unsafe");
# Where a home's skill lives: Codex reads one skill every home shares
# (~/.agents/skills, cli.md "integration install"), Claude one per config home.
def skill_loc: if .agent == "codex" or (.skill.shared // false) then ["shared", .agent]
               elif (.skill.path | type) == "string" then ["path", .skill.path]
               else ["home"] + home_key end;

($snapshot.projects // []) as $p0
| ($snapshot.profiles // []) as $pr0
| ($snapshot.integrations.agents // []) as $i0
| [($now.projects // [])[] | .id] as $p1
| {
    projects_added: [$p1[] | select(IN($p0[]) | not)] | unique,
    profiles_created: [($now.profiles.profiles // [])[]
                       | select(.name as $n | [$pr0[] | .name] | index($n) | not)
                       | {name, file_digest: (.file_digest // null)}],
    groups_known: ($snapshot.sessions != null),
    groups_set: (if $snapshot.sessions == null then [] else
      ($snapshot.sessions | map({key: .id, value: .group}) | from_entries) as $g0
      | [($now.sessions // [])[]
         | .id as $id
         | select($id != $own and ($g0 | has($id)) and $g0[$id] == null)
         | select((.metadata["companion.group"] // null) != null)
         | {session_id: .id, group: .metadata["companion.group"]}]
    end),
    integrations: [($now.integrations.agents // [])[]
      | home_key as $k
      | skill_loc as $loc
      | ([$i0[] | select(home_key == $k)] | first) as $before
      | {agent: $k[0], profile: $k[1],
         hooks: (hooks_present and (($before // {}) | hooks_present | not)),
         skill: (skill_present and ([$i0[] | select(skill_loc == $loc and skill_present)] | length == 0))}
      | select(.hooks or .skill)],
    agent_versions: (if $snapshot.agents == null then [] else
      ($snapshot.agents | map({key: .agent, value: .version}) | from_entries) as $v0
      | [($now.inspect.runtimes // [])[]
         | .agent as $a
         | select($a == (.agent_base // $a) and ($v0 | has($a)))
         | {agent, before: $v0[.agent], after: (.version // null)}
         | select(.before != .after)]
    end)
  }
