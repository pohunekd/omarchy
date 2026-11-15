# The Undo plan of an onboarding run: what to remove, in order, and what is
# kept. Pure: `jq -n --argjson in INPUT -f onboard-undo.jq`, INPUT being
#
#   record   the onboarding record (snapshot, profile)
#   diff     the run's changes (tools/onboard-diff.jq)
#   bound    true when the diff was taken when the onboard session ended (the
#            tool watched it end); false when it is computed now, after the
#            fact, so it may hold changes made after the run
#   ended    the session's ended_at, or null when unknown
#   now      current answers: projects (`project list` .ok), profiles (`plugin
#            profile list --all` .ok), sessions (`session list` .ok),
#            integrations (`integration status --all-profiles` .ok)
#   can_rm   whether this pohunek has `plugin profile rm`
#   done     action keys an earlier Undo attempt completed
#   rm_version  the version that adds `plugin profile rm`
#
# Every action has a stable key; an action in `done` is not repeated. Only an
# item the run provably added is removed: with a late diff that is a manual
# project registered before the session ended and the tool's own
# pohunek-onboard at its recorded digest. Anything the snapshot shows before
# the run is refused: hooks by their home, a skill by its location (Codex
# homes share one). Hooks are removed only when every skill the removal takes
# with it was added by the run (core has no hooks-only uninstall).

def id_ok: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$");
def name_ok: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$");
def digest_ok: type == "string" and test("^sha256:[0-9a-f]{64}$");
# Seconds since the epoch of an RFC3339 UTC timestamp (the daemon's format,
# fractional seconds allowed); null when it is not one.
def ts: try (capture("^(?<s>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<f>\\.[0-9]+)?(?<z>Z|[+-]00:00)$")
             | ((.s + "Z") | fromdateiso8601) + ("0" + (.f // ".0") | tonumber)) catch null;
def home($i): $i.agent + (if $i.profile then ":" + $i.profile else "" end);
def key_of($i): "\($i.agent):\($i.profile // "")";
def status_key: [.agent, (.home.selector // {kind: "default"} | if .kind == "profile" then .name else null end)];
def hooks_present: (.state // "not_installed") != "not_installed";
def skill_present: (.skill.state // "absent") | IN("current", "stale", "modified", "foreign", "unsafe");
# The location of a home's skill, as tools/onboard-diff.jq compares it.
def skill_loc: if .agent == "codex" or (.skill.shared // false) then ["shared", .agent]
               elif (.skill.path | type) == "string" then ["path", .skill.path]
               else ["home"] + status_key end;
def uninstall($i; $skill): ["integration", "uninstall", "--agent", $i.agent]
  + (if $i.profile then ["--profile", $i.profile] else [] end)
  + (if $skill then ["--skill"] else [] end) + ["--json"];
def cannot_prove($what): "\($what): cannot prove onboarding added it (the run's changes were not recorded when its session ended), so it is kept";

$in.record as $r | $in.diff as $d0 | $in.bound as $bound | $in.now as $now | ($in.done // []) as $done
| ($r.snapshot // {}) as $snap
| [($snap.projects // [])[]] as $p0
| [($snap.profiles // [])[] | .name] as $pr0
| (($snap.sessions // []) | map({key: .id, value: .group}) | from_entries) as $g0
| ($in.ended | ts) as $ended
| ($d0 | .projects_added |= map(select(id_ok))
       | .profiles_created |= map(select((.name | name_ok) and (.file_digest | digest_ok)))
       | .groups_set |= map(select(.session_id | id_ok))
       | .integrations |= map(select((.agent == "claude" or .agent == "codex") and (.profile == null or (.profile | name_ok))))) as $d
| ($now.projects // []) as $projects
| (($now.profiles // {}).profiles // []) as $cur
| [$cur[] | .name] as $names
| ($now.sessions // []) as $sessions
| (($now.integrations // {}).agents // []) as $status
| ($r.profile // null) as $own
| (($snap.integrations // {}).agents // []) as $i0
# ---- integrations the snapshot shows before the run are refused
| [$d.integrations[] | . as $i
   | ([$status[] | select(status_key == [$i.agent, $i.profile])] | first) as $now_i
   | (if $now_i != null then ($now_i | skill_loc)
      else ({agent: $i.agent, home: {selector: (if $i.profile then {kind: "profile", name: $i.profile} else {kind: "default"} end)}} | skill_loc) end) as $loc
   | {i: $i,
      hooks_before: ($i.hooks and ([$i0[] | select(status_key == [$i.agent, $i.profile] and hooks_present)] | length > 0)),
      skill_before: ($i.skill and ([$i0[] | select(skill_loc == $loc and skill_present)] | length > 0))}] as $judged
| ([$judged[] | select(.hooks_before) | "hooks in \(home(.i)): they were installed before the run, so they are kept"]
   + ([$judged[] | select(.skill_before)
       | if .i.agent == "codex" then "agent skill of Codex: it was installed before the run, so it is kept"
         else "agent skill in \(home(.i)): it was installed before the run, so it is kept" end] | unique)) as $int_refused
| ($d | .integrations = [$judged[] | .i + {hooks: (.i.hooks and (.hooks_before | not)), skill: (.i.skill and (.skill_before | not))}
                         | select(.hooks or .skill)]) as $d
# ---- projects
| [$d.projects_added[] | . as $id | ($projects | map(select(.id == $id)) | first) as $row
   | if IN($p0[]) then {refused: "project \($id): it was registered before the run, so it is kept"}
     elif $row == null then {gone: "project \($id)"}
     elif ($row.source // "") != "manual" then {kept: "project \($id): auto-registered by a session, not added by onboarding, so it is kept"}
     elif ($bound | not) and (($row.added_at | ts) as $t | $t == null or $ended == null or $t > $ended)
       then {kept: cannot_prove("project \($id)")}
     else {action: {key: "project:\($id)", label: "project \($id) (\($row.label // "" | tostring))", argv: ["project", "rm", $id, "--json"]}} end] as $proj
# ---- profiles
| [$d.profiles_created[] | . as $c | ($cur | map(select(.name == $c.name)) | first) as $nowp
   | ($own != null and $own.name == $c.name and $own.replaced == null and $own.file_digest == $c.file_digest) as $tools_own
   | if IN($pr0[]; $c.name) then {refused: "profile \($c.name): it existed before the run, so it is kept"}
     elif $nowp == null then {gone: "profile \($c.name)"}
     elif ($bound | not) and ($tools_own | not) then {kept: cannot_prove("profile \($c.name)")}
     elif $nowp.file_digest != $c.file_digest then {kept: "profile \($c.name): edited after onboarding (now \($nowp.file_digest)), so it is kept"}
     elif ($in.can_rm | not) then {kept: "profile \($c.name): removing it needs pohunek \($in.rm_version) or newer (plugin profile rm), so it is kept"}
     else {remove: $c.name, digest: $c.file_digest} end] as $profs
| [$profs[] | select(.remove) | .remove] as $removing
# ---- hooks and skills, judged against the current status
| [$status[] | select(.agent == "codex" and skill_present)] as $codex_skill_now
| ([$d.integrations[] | select(.agent == "codex" and .skill)] | length > 0) as $codex_skill_new
| [$d.integrations[] | select(.profile == null or (.profile as $n | $names | index($n)))
   | . as $i | ([$status[] | select(status_key == [$i.agent, $i.profile])] | first) as $now_i
   # The skills a hooks removal of this home takes with it: the home's own
   # (Claude), or the shared Codex skill for the bare runtime; a Codex
   # --profile removal keeps the shared one.
   | (if $i.agent == "codex" then ($i.profile == null and ($codex_skill_now | length > 0))
      else (($now_i // {}) | skill_present) end) as $takes_skill
   | (if $i.agent == "codex" then $codex_skill_new else $i.skill end) as $skill_ours
   | {i: $i, hooks_now: (($now_i // {}) | hooks_present), takes_skill: $takes_skill, skill_ours: $skill_ours,
      skill_now: (if $i.agent == "codex" then ($codex_skill_now | length > 0) else (($now_i // {}) | skill_present) end)}] as $homes
| [$homes[] | select(.i.hooks)
   | if ($bound | not) then (if .hooks_now then {kept: cannot_prove("hooks in \(home(.i))")} else {gone: "hooks in \(home(.i))"} end)
     elif (.hooks_now | not) then {gone: "hooks in \(home(.i))"}
     elif .takes_skill and (.skill_ours | not) then
       {kept: "hooks in \(home(.i)): removing them also removes the pohunek agent skill there, which onboarding did not add, so both are kept; remove them together with `pohunek \(uninstall(.i; false)[:-1] | join(" "))`"}
     else {action: {key: "hooks:\(key_of(.i))", profile: .i.profile,
                    label: (if .takes_skill then "hooks and agent skill in \(home(.i))" else "hooks in \(home(.i))" end),
                    argv: uninstall(.i; false), skill_too: .takes_skill, agent: .i.agent, home_profile: .i.profile}} end] as $hooks
| [$hooks[] | .action? // empty] as $hook_actions
| ([$hook_actions[] | select(.agent == "codex" and .home_profile == null and .skill_too)] | length > 0) as $codex_skill_covered
| ([$homes[] | select(.i.skill and .i.agent != "codex")
   | . as $h | ([$hook_actions[] | select(.agent == $h.i.agent and .home_profile == $h.i.profile and .skill_too)] | length > 0) as $covered
   | if $covered then empty
     elif ($bound | not) then (if .skill_now then {kept: cannot_prove("agent skill in \(home(.i))")} else empty end)
     elif .skill_now then {action: {key: "skill:\(key_of(.i))", label: "agent skill in \(home(.i))", argv: uninstall(.i; true)}}
     else {gone: "agent skill in \(home(.i))"} end]
  + (if $codex_skill_new and ($codex_skill_covered | not) then
       (if ($bound | not) then (if ($codex_skill_now | length > 0) then [{kept: cannot_prove("agent skill of Codex")}] else [] end)
        elif ($codex_skill_now | length > 0) then
          [{action: {key: "skill:codex:", label: "agent skill of Codex (shared by every Codex home)",
                     argv: uninstall({agent: "codex", profile: null}; true)}}]
        else [{gone: "agent skill of Codex"}] end)
     else [] end)) as $skills
# ---- groups
| [$d.groups_set[] | . as $g | ($sessions | map(select(.id == $g.session_id)) | first) as $row
   | if ($g0 | has($g.session_id) | not) or $g0[$g.session_id] != null
       then {refused: "group of session \($g.session_id): the session was not ungrouped before the run, so it is kept"}
     elif $row == null then {gone: "session \($g.session_id)"}
     elif ($row.metadata["companion.group"] // null) == null then {gone: "group of session \($g.session_id) (already cleared)"}
     elif ($row.metadata["companion.group"]) != $g.group then {kept: "group of session \($g.session_id): changed since onboarding, so it is kept"}
     elif ($bound | not) then {kept: cannot_prove("group \($g.group) of session \($g.session_id)")}
     else {action: {key: "group:\($g.session_id)", label: "group \($g.group) of session \($g.session_id)", group: $g.group,
                    argv: ["session", "metadata", $g.session_id, "--clear", "companion.group", "--json"]}} end] as $groups
# ---- the replaced pohunek-onboard
| (if $own != null and $own.replaced != null then
     ($cur | map(select(.name == $own.name)) | first) as $nowp
     | ["profile \($own.name): this run replaced an earlier version (\($own.replaced)) with \($own.file_digest)"
        + (if $nowp != null and $nowp.file_digest != $own.file_digest then ", and it was edited since" else "" end)
        + "; the earlier version cannot be restored, so it is kept"]
   else [] end) as $replaced
| ([$proj[] | .action? // empty]
   + [$profs[] | select(.remove) | . as $p
      | ($hook_actions | map(select(.home_profile == $p.remove)))
        + [{key: "profile:\($p.remove)", label: "profile \($p.remove) (\($p.digest))", profile: $p.remove, removes_profile: true,
            argv: ["plugin", "profile", "rm", $p.remove, "--digest", $p.digest, "--json"]}]
      | .[]]
   + [$groups[] | .action? // empty]
   + [$hook_actions[] | select(.home_profile == null or (.home_profile as $n | $removing | index($n) | not))]
   + [$skills[] | .action? // empty]) as $all
| {
    actions: [$all[] | select(.key as $k | $done | index($k) | not) | del(.skill_too, .agent, .home_profile)],
    done_before: [$all[] | select(.key as $k | $done | index($k)) | .label],
    kept: ([$proj[], $profs[], $hooks[], $skills[], $groups[] | .kept? // empty] + $replaced
           + [$d.integrations[] | select(.profile != null and (.profile as $n | $names | index($n) | not))
              | "hooks in \(home(.)): the profile is gone, so pohunek cannot reach its home; remove them by hand"]),
    refused: ([$proj[], $profs[], $groups[] | .refused? // empty] + $int_refused),
    gone: [$proj[], $profs[], $hooks[], $skills[], $groups[] | .gone? // empty]
  }
