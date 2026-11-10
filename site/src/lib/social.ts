/** Open Graph and Twitter card tags of a page, with absolute URLs. */
export interface SocialInput {
	title: string;
	description: string;
	/** Absolute URL of the page. */
	url: string;
	/** Absolute URL of the preview image. */
	image: string;
	imageAlt: string;
	imageWidth: number;
	imageHeight: number;
	siteName: string;
}

export interface MetaTag {
	/** Attribute naming the tag: Open Graph uses `property`, Twitter cards use `name`. */
	attr: 'property' | 'name';
	key: string;
	content: string;
}

export function socialTags(i: SocialInput): MetaTag[] {
	const og = (key: string, content: string): MetaTag => ({ attr: 'property', key: `og:${key}`, content });
	const tw = (key: string, content: string): MetaTag => ({ attr: 'name', key: `twitter:${key}`, content });
	return [
		og('type', 'website'),
		og('site_name', i.siteName),
		og('title', i.title),
		og('description', i.description),
		og('url', i.url),
		og('image', i.image),
		og('image:type', 'image/png'),
		og('image:width', String(i.imageWidth)),
		og('image:height', String(i.imageHeight)),
		og('image:alt', i.imageAlt),
		tw('card', 'summary_large_image'),
		tw('title', i.title),
		tw('description', i.description),
		tw('image', i.image),
		tw('image:alt', i.imageAlt),
	];
}

/** Content of every `<meta property|name=... content=...>` tag, keyed by property or name. */
export function metaTags(html: string): Map<string, string[]> {
	const found = new Map<string, string[]>();
	for (const m of html.matchAll(/<meta\b[^>]*>/gi)) {
		const tag = m[0];
		const key = /\b(?:property|name)\s*=\s*"([^"]*)"/i.exec(tag)?.[1];
		const content = /\bcontent\s*=\s*"([^"]*)"/i.exec(tag)?.[1];
		if (key === undefined || content === undefined) continue;
		const decoded = content.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
		found.set(key, [...(found.get(key) ?? []), decoded]);
	}
	return found;
}

/** Problems that make a page's link preview incomplete; empty when it is fine. */
export function socialProblems(html: string, origin: string): string[] {
	const tags = metaTags(html);
	const problems: string[] = [];
	const one = (key: string): string | undefined => {
		const v = tags.get(key);
		if (!v || v.length !== 1 || v[0].trim() === '') {
			problems.push(`${key}: expected exactly one non-empty tag, found ${v?.length ?? 0}`);
			return undefined;
		}
		return v[0];
	};
	for (const key of ['og:title', 'og:description', 'og:type', 'og:image', 'og:url', 'twitter:title', 'twitter:description', 'twitter:image']) {
		const value = one(key);
		if (value !== undefined && ['og:image', 'og:url', 'twitter:image'].includes(key) && !value.startsWith(`${origin}/`)) {
			problems.push(`${key}: ${value} is not an absolute ${origin} URL`);
		}
	}
	const card = one('twitter:card');
	if (card !== undefined && card !== 'summary_large_image') problems.push(`twitter:card: ${card}, expected summary_large_image`);
	if (tags.get('og:image')?.[0] !== tags.get('twitter:image')?.[0]) problems.push('og:image and twitter:image differ');
	return problems;
}
