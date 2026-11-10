/** Escapes HTML and turns `backtick` spans into <code>, so copy can mark commands without raw markup. */
export function inlineCode(text: string): string {
	const escaped = text.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c] as string);
	return escaped.replace(/`([^`]+)`/g, '<code>$1</code>');
}
