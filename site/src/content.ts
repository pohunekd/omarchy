/** Page copy. Every claim here is taken from README.md, docs/, CHANGELOG.md or manifest.json. */

export const REPO = 'https://github.com/pohunekd/omarchy';
export const INSTALL_COMMAND = 'omarchy plugin add https://github.com/pohunekd/omarchy --enable';

export const WORKSPACES = [
	{ n: 1, id: 'top', name: 'overview' },
	{ n: 2, id: 'tour', name: 'tour' },
	{ n: 3, id: 'install', name: 'install' },
	{ n: 4, id: 'keys', name: 'keys' },
	{ n: 5, id: 'hosts', name: 'hosts' },
	{ n: 6, id: 'safe', name: 'safe by design' },
];

export const WHY = [
	{
		id: 'needs',
		title: 'Needs you, first',
		text: 'Sessions blocked on an approval or a question sit on top of every view, from every host, oldest wait first. The bar icon turns amber and counts them. A desktop notification pops up; click it and you are in that session’s terminal.',
		signal: true,
	},
	{
		id: 'machines',
		title: 'Every machine, one list',
		text: 'This machine, your other Omarchy machines and any pohunek daemon on your NetBird or Tailscale network, side by side, each row with its host chip. A machine that drops off keeps its rows, dimmed.',
	},
	{
		id: 'terminal',
		title: 'A real terminal, one click away',
		text: 'Enter or a click attaches (`pohunek attach`); `Ctrl+]` detaches and the agent keeps working.',
	},
	{
		id: 'groups',
		title: 'Your groups, everywhere',
		text: 'Groups live in the session’s `companion.group` metadata, so they are the same groups the pohunek desktop and Android companions show.',
	},
	{
		id: 'new',
		title: 'New sessions without the CLI',
		text: 'Pick a host, a project and an agent (with fuzzy search when the lists get long), write the first prompt, `Ctrl+Enter`.',
	},
];

export type ShotKey = 'list' | 'state' | 'actions' | 'new' | 'help' | 'hosts';

export const TOUR: Array<{ shot: ShotKey; window: string; name: string; text: string; alt: string }> = [
	{
		shot: 'list',
		window: 'pohunek - my groups',
		name: 'My groups',
		text: 'Needs you on top, then Inbox and your own groups. Each row: state, agent, project, Work link (GH PR #1412), branch, host.',
		alt: 'The panel in My groups view: two sessions that need you on top, then the Inbox and Dependencies groups with working and idle sessions.',
	},
	{
		shot: 'state',
		window: 'pohunek - by state',
		name: 'By state',
		text: 'Needs you, Working, Idle, Runtime problem. Ended sessions stay hidden until you pick them.',
		alt: 'The panel in By state view, sessions grouped under Needs you, Working and Idle.',
	},
	{
		shot: 'actions',
		window: 'pohunek - actions',
		name: 'Actions',
		text: 'Open terminal, details, rename, new session here, move to group, open link, diff, stop, remove, resume. Reach them with the three-dot button, a right click or the right arrow key.',
		alt: 'The row actions sheet listing open terminal, details, rename, new session here, move to group, open link, diff, stop, remove and resume.',
	},
	{
		shot: 'new',
		window: 'pohunek - new session',
		name: 'New session',
		text: 'Host, project, agent, name, branch (a fresh worktree), first prompt. Long lists turn into a fuzzy search select.',
		alt: 'The new session form with host, project, agent, name, branch and first prompt fields.',
	},
	{
		shot: 'help',
		window: 'pohunek - help',
		name: 'Help',
		text: 'Press ? for every key in the panel and, most importantly, the ones inside an attached terminal.',
		alt: 'The help page listing the panel keys and the keys inside an attached terminal.',
	},
	{
		shot: 'hosts',
		window: 'pohunek - hosts',
		name: 'Hosts',
		text: 'Every pohunek daemon you can reach, the network that carries them, and your Omarchy machines that do not run pohunek yet.',
		alt: 'The hosts page listing reachable pohunek daemons, the overlay network and Omarchy machines without pohunek.',
	},
];

export const CURSORS = [
	{ state: 'needs', label: 'amber', meaning: 'a session needs you (the number beside it says how many)' },
	{ state: 'bad', label: 'red', meaning: 'a runtime problem (a worker conflict; open Details)' },
	{ state: 'ok', label: 'green', meaning: 'agents are working' },
	{ state: 'quiet', label: 'cut out', meaning: 'all quiet' },
] as const;

export const BAR_MOUSE = [
	{ action: 'click', does: 'opens the panel' },
	{ action: 'middle click', does: 'jumps straight into the session that has waited longest for you' },
	{ action: 'right click', does: 'refreshes every host' },
];

export type KeyRow = { keys: string[]; does: string };

export const KEYS_OMARCHY: KeyRow[] = [
	{ keys: ['Super', 'Alt', 'P'], does: 'open the pohunek panel' },
	{ keys: ['Super', 'Shift', 'Alt', 'P'], does: 'start a new session' },
];

export const KEYS_ATTACHED: KeyRow[] = [
	{ keys: ['Ctrl', ']'], does: 'detach: close the terminal, the agent keeps running' },
	{ keys: ['Ctrl', '\\'], does: 'session menu over the agent screen' },
	{ keys: ['k', 'y'], does: 'in the menu: kill the session' },
	{ keys: ['t', 'y'], does: 'in the menu: terminate and delete it, worktree included' },
	{ keys: ['d'], does: 'in the menu: detach' },
	{ keys: ['n'], does: 'in the menu: new session in the same worktree' },
	{ keys: ['r'], does: 'in the menu: rename' },
];

export const KEYS_PANEL: KeyRow[] = [
	{ keys: ['↑', '↓'], does: 'move' },
	{ keys: ['Enter'], does: 'attach, or fold a group' },
	{ keys: ['→'], does: 'row actions' },
	{ keys: ['n'], does: 'new session' },
	{ keys: ['i', 'd', 'o'], does: 'details, diff, open Work link' },
	{ keys: ['e', 'g'], does: 'rename, move to group' },
	{ keys: ['?'], does: 'help' },
	{ keys: ['/'], does: 'search every host' },
	{ keys: ['s', 'p'], does: 'State / Project filter' },
	{ keys: ['v'], does: 'My groups / By state' },
	{ keys: ['c'], does: 'clear filters' },
	{ keys: ['H'], does: 'hosts' },
	{ keys: ['r'], does: 'refresh' },
	{ keys: ['Esc'], does: 'back, close' },
];

export const HOSTS = [
	{ link: 'unix socket', name: 'workstation', agents: 'claude · codex' },
	{ link: 'NetBird / Tailscale', name: 'buildbox', agents: 'codex · claude' },
	{ link: 'NetBird / Tailscale', name: 'laptop', agents: 'claude' },
];

export const OVERLAYS = [
	{ row: 'pohunek', netbird: 'default, nothing to configure', tailscale: 'providers = ["tailscale"] in ~/.config/pohunek/overlays.toml' },
	{ row: 'Omarchy', netbird: 'AUR netbird-bin', tailscale: 'omarchy install service tailscale (+ bar widget, Taildrop)' },
	{ row: 'Self-hosted', netbird: 'NetBird management server', tailscale: 'Headscale' },
	{ row: 'Join', netbird: 'netbird up --management-url …', tailscale: 'sudo tailscale up' },
];

export const SAFE = [
	{
		title: 'Reads first',
		text: 'The list comes from `pohunek session list --json` and `notifications list --unread --json`; nothing changes a session until you pick an action, and stop/remove ask first.',
	},
	{
		title: 'Plain text only',
		text: 'Session names, prompts and notification text are untrusted: bounded, stripped of control and bidi characters, never rendered as markup.',
	},
	{
		title: 'No shell strings',
		text: 'Every command is an argv array. Only ids matching the pohunek session-id shape and validated SSH targets ever reach one; the notification click uses Omarchy’s `--exec`, never a string.',
	},
	{
		title: 'Verified installs',
		text: '`tools/install-pohunek` checks the release SHA-256 and, when `gh` is signed in, its GitHub build attestation, then hands over to the release’s own installer, which verifies its MANIFEST. Agent hooks are offered, never installed silently.',
	},
];

export const NOT_AFFILIATED = 'Not affiliated with Omarchy or Basecamp. Omarchy is a project by Basecamp/DHH.';
