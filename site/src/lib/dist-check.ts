/** Static checks over built HTML and CSS: no external requests, alt text, document language. */

const EXTERNAL = /^(?:[a-z][a-z0-9+.-]*:)?\/\//i;

function attrs(tag: string): Record<string, string> {
	const out: Record<string, string> = {};
	for (const m of tag.matchAll(/([a-zA-Z_:][-a-zA-Z0-9_:.]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g)) {
		out[m[1].toLowerCase()] = m[2] ?? m[3] ?? m[4] ?? '';
	}
	return out;
}

function urlsOf(srcset: string): string[] {
	return srcset.split(',').map((c) => c.trim().split(/\s+/)[0]).filter(Boolean);
}

/** Subresources a browser fetches on load. Plain `<a href>` links are navigation, not requests. */
export function externalRequests(html: string): string[] {
	const found: string[] = [];
	// Any element can pull a resource through an inline style.
	for (const m of html.matchAll(/<[a-z][^>]*>/gi)) {
		const style = attrs(m[0]).style;
		if (style) found.push(...cssExternal(style.replace(/&(?:quot|#34);/gi, '"').replace(/&(?:apos|#39);/gi, "'")));
	}
	// SVG <image>/<use>/<feImage> reference resources through href or xlink:href.
	for (const m of html.matchAll(/<(image|use|feimage)\b[^>]*>/gi)) {
		const a = attrs(m[0]);
		for (const c of [a.href, a['xlink:href']]) if (c && EXTERNAL.test(c)) found.push(`svg ${m[1].toLowerCase()}: ${c}`);
	}
	for (const m of html.matchAll(/<(img|source|script|link|iframe|video|audio|embed|object|track|input)\b[^>]*>/gi)) {
		const tag = m[1].toLowerCase();
		const a = attrs(m[0]);
		const candidates: string[] = [];
		if (a.src) candidates.push(a.src);
		if (a.srcset) candidates.push(...urlsOf(a.srcset));
		if (a.data) candidates.push(a.data);
		if (a.poster) candidates.push(a.poster);
		if (tag === 'link' && a.href && /\b(stylesheet|icon|preload|prefetch|modulepreload|manifest|preconnect|dns-prefetch)\b/i.test(a.rel ?? '')) {
			candidates.push(a.href);
		}
		for (const c of candidates) if (EXTERNAL.test(c)) found.push(`${tag}: ${c}`);
	}
	for (const m of html.matchAll(/<style\b[^>]*>([\s\S]*?)<\/style>/gi)) found.push(...cssExternal(m[1]));
	return found;
}

export function cssExternal(css: string): string[] {
	const found: string[] = [];
	for (const m of css.matchAll(/url\(\s*(['"]?)([^'")]+)\1\s*\)/gi)) {
		if (EXTERNAL.test(m[2].trim())) found.push(`css url: ${m[2]}`);
	}
	for (const m of css.matchAll(/@import\s+(?:url\(\s*)?['"]?([^'")\s;]+)/gi)) {
		if (EXTERNAL.test(m[1])) found.push(`css import: ${m[1]}`);
	}
	return found;
}

/** Script bundles must not reach for the network. */
export function scriptNetworkUse(js: string): string[] {
	const found: string[] = [];
	if (/\bfetch\s*\(/.test(js)) found.push('fetch()');
	if (/XMLHttpRequest|sendBeacon|WebSocket|EventSource/.test(js)) found.push('network API');
	if (/https?:\/\/(?!www\.w3\.org\/)/i.test(js)) found.push('absolute URL');
	return found;
}

export function imagesWithoutAlt(html: string): string[] {
	const bad: string[] = [];
	for (const m of html.matchAll(/<img\b[^>]*>/gi)) {
		if (!('alt' in attrs(m[0]))) bad.push(m[0].slice(0, 120));
	}
	return bad;
}

export function hasLang(html: string): boolean {
	const m = /<html\b[^>]*>/i.exec(html);
	return !!m && !!attrs(m[0]).lang;
}
