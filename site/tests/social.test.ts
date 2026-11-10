import { describe, expect, test } from 'bun:test';
import { metaTags, socialProblems, socialTags } from '../src/lib/social';

const ORIGIN = 'https://omarchy.pohunek.dev';
const input = {
	title: 'A "quoted" & <tagged> title',
	description: 'Description',
	url: `${ORIGIN}/`,
	image: `${ORIGIN}/social.png`,
	imageAlt: 'alt',
	imageWidth: 1200,
	imageHeight: 630,
	siteName: 'Site',
};
const render = (tags: ReturnType<typeof socialTags>) =>
	tags.map((t) => `<meta ${t.attr}="${t.key}" content="${t.content.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;')}" />`).join('\n');

describe('social tags', () => {
	test('a complete set passes and round-trips escaped text', () => {
		const html = render(socialTags(input));
		expect(socialProblems(html, ORIGIN)).toEqual([]);
		expect(metaTags(html).get('og:title')).toEqual([input.title]);
	});
	test('a missing tag, a relative image or a wrong card type is reported', () => {
		const tags = socialTags(input);
		expect(socialProblems(render(tags.filter((t) => t.key !== 'og:image')), ORIGIN).join('\n')).toContain('og:image');
		expect(socialProblems(render(socialTags({ ...input, image: '/social.png' })), ORIGIN).join('\n')).toContain('not an absolute');
		expect(socialProblems(render(tags.map((t) => (t.key === 'twitter:card' ? { ...t, content: 'summary' } : t))), ORIGIN).join('\n')).toContain('summary_large_image');
	});
});
