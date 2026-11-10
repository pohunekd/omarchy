/**
 * Progressive enhancement. The page is complete without this script: it adds the
 * theme picker, the workspace indicator, the clock, copy buttons, focus-follows-
 * pointer and the scroll reveal.
 */
import { CLOCK_TICK_MS, COPIED_RESET_MS, REVEAL_MARGIN, THEME_STORAGE_KEY, WORKSPACE_MARGIN } from '../config/site';
import { DEFAULT_DARK, DEFAULT_LIGHT, THEMES } from '../config/themes';

const root = document.documentElement;
const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
const known = new Set(THEMES.map((t) => t.id));

function currentThemeId(): string {
	const set = root.getAttribute('data-theme');
	if (set && known.has(set)) return set;
	return matchMedia('(prefers-color-scheme: light)').matches ? DEFAULT_LIGHT : DEFAULT_DARK;
}

function initPicker(): void {
	const group = document.querySelector<HTMLElement>('[data-picker]');
	if (!group) return;
	const buttons = Array.from(group.querySelectorAll<HTMLButtonElement>('[data-theme-id]'));
	const name = group.querySelector<HTMLElement>('[data-theme-name]');
	const labels = new Map(THEMES.map((t) => [t.id, t.label]));

	const paint = (id: string): void => {
		for (const b of buttons) {
			const on = b.dataset.themeId === id;
			b.setAttribute('aria-checked', String(on));
			b.tabIndex = on ? 0 : -1;
		}
		if (name) name.textContent = labels.get(id) ?? id;
	};
	const choose = (id: string): void => {
		if (!known.has(id)) return;
		root.setAttribute('data-theme', id);
		try {
			localStorage.setItem(THEME_STORAGE_KEY, id);
		} catch {
			// Storage can be blocked; the choice then lasts for this page view only.
		}
		paint(id);
	};

	group.hidden = false;
	paint(currentThemeId());
	for (const b of buttons) b.addEventListener('click', () => choose(b.dataset.themeId ?? ''));
	group.addEventListener('keydown', (e) => {
		const keys = ['ArrowRight', 'ArrowDown', 'ArrowLeft', 'ArrowUp', 'Home', 'End'];
		if (!keys.includes(e.key)) return;
		e.preventDefault();
		const i = buttons.findIndex((b) => b.getAttribute('aria-checked') === 'true');
		let next = i;
		if (e.key === 'Home') next = 0;
		else if (e.key === 'End') next = buttons.length - 1;
		else next = (i + (e.key === 'ArrowRight' || e.key === 'ArrowDown' ? 1 : -1) + buttons.length) % buttons.length;
		buttons[next].focus();
		choose(buttons[next].dataset.themeId ?? '');
	});
}

function initWorkspaces(): void {
	const links = Array.from(document.querySelectorAll<HTMLAnchorElement>('[data-ws]'));
	const sections = Array.from(document.querySelectorAll<HTMLElement>('[data-ws-section]'));
	if (!('IntersectionObserver' in window) || !links.length) return;
	const io = new IntersectionObserver(
		(entries) => {
			for (const e of entries) {
				if (!e.isIntersecting) continue;
				const id = (e.target as HTMLElement).dataset.wsSection;
				for (const l of links) {
					const on = l.dataset.ws === id;
					l.classList.toggle('is-active', on);
					if (on) l.setAttribute('aria-current', 'true');
					else l.removeAttribute('aria-current');
				}
			}
		},
		{ rootMargin: WORKSPACE_MARGIN },
	);
	for (const s of sections) io.observe(s);
}

function initClock(): void {
	const el = document.querySelector<HTMLTimeElement>('[data-clock]');
	if (!el) return;
	const fmt = new Intl.DateTimeFormat(undefined, { weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
	const tick = (): void => {
		const now = new Date();
		el.dateTime = now.toISOString();
		el.textContent = fmt.format(now);
	};
	el.hidden = false;
	tick();
	setInterval(tick, CLOCK_TICK_MS);
}

function initCopy(): void {
	for (const btn of document.querySelectorAll<HTMLButtonElement>('[data-copy]')) {
		const source = btn.parentElement?.querySelector<HTMLElement>('[data-copy-source]');
		if (!source || !navigator.clipboard) continue;
		btn.hidden = false;
		const label = btn.getAttribute('aria-label') ?? 'Copy';
		btn.addEventListener('click', async () => {
			try {
				await navigator.clipboard.writeText(source.textContent ?? '');
				btn.textContent = 'copied';
			} catch {
				btn.textContent = 'failed';
			}
			btn.setAttribute('aria-label', btn.textContent === 'copied' ? 'Copied' : 'Copy failed');
			setTimeout(() => {
				btn.textContent = 'copy';
				btn.setAttribute('aria-label', label);
			}, COPIED_RESET_MS);
		});
	}
}

function initFocusFollowsPointer(): void {
	const tiles = Array.from(document.querySelectorAll<HTMLElement>('[data-tile]'));
	const focus = (t: HTMLElement): void => {
		for (const o of tiles) o.classList.toggle('is-focus', o === t);
	};
	if (tiles.length) focus(tiles[0]);
	for (const t of tiles) {
		t.addEventListener('pointerenter', () => focus(t));
		t.addEventListener('focusin', () => focus(t));
	}
}

function initReveal(): void {
	const items = Array.from(document.querySelectorAll<HTMLElement>('[data-reveal]'));
	if (reduced || !('IntersectionObserver' in window)) return;
	root.classList.add('reveal');
	const io = new IntersectionObserver(
		(entries) => {
			for (const e of entries) {
				if (!e.isIntersecting) continue;
				(e.target as HTMLElement).classList.add('in');
				io.unobserve(e.target);
			}
		},
		{ rootMargin: REVEAL_MARGIN },
	);
	for (const i of items) io.observe(i);
}

initPicker();
initWorkspaces();
initClock();
initCopy();
initFocusFollowsPointer();
initReveal();
