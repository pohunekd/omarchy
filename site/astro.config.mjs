// @ts-check
import { defineConfig } from 'astro/config';

export default defineConfig({
	site: 'https://omarchy.pohunek.dev',
	trailingSlash: 'always',
	// Keeps line breaks between text and inline elements (kbd, links) intact.
	compressHTML: false,
	devToolbar: { enabled: false },
	build: { inlineStylesheets: 'auto' },
});
