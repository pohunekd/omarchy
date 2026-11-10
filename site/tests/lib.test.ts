import { describe, expect, test } from 'bun:test';
import { cssExternal, externalRequests, hasLang, imagesWithoutAlt, scriptNetworkUse } from '../src/lib/dist-check';
import { latestRelease } from '../src/lib/facts';

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
	test('reads the newest changelog heading', () => {
		expect(latestRelease('# Changelog\n\n## 0.4.0 - 2026-12-01\n\n## 0.3.0 - 2026-11-10\n')).toEqual({
			version: '0.4.0',
			date: '2026-12-01',
		});
		expect(latestRelease('# Changelog')).toBeNull();
	});
});

import { inlineCode } from '../src/lib/text';

describe('inlineCode', () => {
	test('marks backtick spans and escapes everything else', () => {
		expect(inlineCode('run `a --b` <b>now</b>')).toBe('run <code>a --b</code> &lt;b&gt;now&lt;/b&gt;');
	});
});
