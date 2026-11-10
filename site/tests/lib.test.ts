import { describe, expect, test } from 'bun:test';
import { cssExternal, externalRequests, hasLang, imagesWithoutAlt, scriptNetworkUse } from '../src/lib/dist-check';
import { readFacts, releaseDate, versionOfTag } from '../src/lib/facts';

describe('dist-check', () => {
	test('flags subresources that leave the origin, not plain links', () => {
		const html = `<link rel="stylesheet" href="https://cdn.example/x.css"><img src="//x.example/a.png" alt="">
			<img srcset="/a.png 1x, https://x.example/b.png 2x" alt="x"><a href="https://github.com/pohunekd/omarchy">repo</a>
			<script src="/_astro/a.js"></script><link rel="canonical" href="https://omarchy.pohunek.dev/">`;
		const found = externalRequests(html);
		expect(found).toHaveLength(3);
		expect(found.join('\n')).not.toContain('github.com');
		expect(found.join('\n')).not.toContain('canonical');
	});
	test('flags external urls in inline and bundled css', () => {
		expect(externalRequests('<style>a{background:url(https://x.example/a.png)}</style>')).toHaveLength(1);
		expect(cssExternal('@import "https://x.example/a.css"; b{src:url(./f.woff2)}')).toHaveLength(1);
	});
	test('flags requests hidden in inline styles, hints and SVG images', () => {
		const found = externalRequests(`<div style="background:url('https://x.example/a.png')"></div>
			<p style="background-image: url(&quot;//y.example/b.png&quot;)"></p>
			<link rel="preconnect" href="https://fonts.example"><link rel="dns-prefetch" href="//fonts.example">
			<svg><image href="https://z.example/c.png"/><image xlink:href="//z.example/d.png"/><use href="#local"/></svg>`);
		expect(found).toHaveLength(6);
		expect(externalRequests('<div style="color:red"></div><svg><image href="/a.png"/></svg>')).toEqual([]);
	});
	test('flags network use in scripts', () => {
		expect(scriptNetworkUse('fetch("/x")')).toContain('fetch()');
		expect(scriptNetworkUse('const a=1')).toEqual([]);
	});
	test('finds images without alt and a missing lang', () => {
		expect(imagesWithoutAlt('<img src="a"><img src="b" alt=""><img alt="c" src="d">')).toHaveLength(1);
		expect(hasLang('<html lang="en">')).toBe(true);
		expect(hasLang('<html>')).toBe(false);
	});
});

describe('facts', () => {
	test('finds the date of the published version, not just the newest heading', () => {
		const log = '# Changelog\n\n## 0.4.0 - 2026-12-01\n\n## 0.3.0 - 2026-11-10\n';
		expect(releaseDate(log, '0.3.0')).toBe('2026-11-10');
		expect(releaseDate(log, '0.30')).toBeNull();
		expect(releaseDate('# Changelog', '0.3.0')).toBeNull();
	});
	test('takes the published release, and refuses to guess without one', () => {
		expect(versionOfTag('v1.2.3')).toBe('1.2.3');
		for (const bad of ['1.2.3', 'v1.2', 'v1.2.3-rc1', '', null]) expect(() => versionOfTag(bad)).toThrow();
		expect(() => readFacts(undefined)).toThrow('SITE_RELEASE_VERSION');
		expect(readFacts('0.3.0').version).toBe('0.3.0');
		expect(readFacts('99.0.0').released).toBeNull();
		expect(readFacts('0.3.0').released).toBe('2026-11-10');
	});
});

import { inlineCode } from '../src/lib/text';

describe('inlineCode', () => {
	test('marks backtick spans and escapes everything else', () => {
		expect(inlineCode('run `a --b` <b>now</b>')).toBe('run <code>a --b</code> &lt;b&gt;now&lt;/b&gt;');
	});
});
