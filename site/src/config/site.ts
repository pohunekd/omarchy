/** Site-wide constants shared by the layout and the client script. */
export const THEME_STORAGE_KEY = 'pohunek-omarchy-theme';
/** Window under which a scroll position counts as "inside" a workspace section. */
export const WORKSPACE_MARGIN = '-40% 0px -55% 0px';
export const COPIED_RESET_MS = 1600;
export const CLOCK_TICK_MS = 15000;
export const REVEAL_MARGIN = '0px 0px -8% 0px';
/** Link preview image, served from public/ and rendered by scripts/render-social.ts. */
export const SOCIAL_IMAGE = {
	path: '/social.png',
	width: 1200,
	height: 630,
	maxBytes: 300 * 1024,
	alt: 'The pohunek panel next to the headline: every coding agent on every machine, in your Omarchy bar.',
};
export const SITE_NAME = 'pohunek for Omarchy';
