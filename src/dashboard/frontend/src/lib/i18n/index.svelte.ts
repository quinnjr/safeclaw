import en from './locales/en.json';

type Messages = Record<string, string>;

const STORAGE_KEY = 'safeclaw-locale';

export const SUPPORTED_LOCALES: Record<string, string> = {
	en: 'English',
	es: 'Español',
	fr: 'Français',
	de: 'Deutsch',
	ja: '日本語',
	'zh-CN': '简体中文',
	'pt-BR': 'Português (Brasil)',
};

const cache = new Map<string, Messages>();
cache.set('en', en);

export const i18n = $state({
	locale: 'en',
	messages: en as Messages,
});

export function t(key: string, params?: Record<string, string | number>): string {
	let msg = i18n.messages[key] ?? (en as Messages)[key] ?? key;
	if (params) {
		for (const [k, v] of Object.entries(params)) {
			msg = msg.replaceAll(`{${k}}`, String(v));
		}
	}
	return msg;
}

const loaders: Record<string, () => Promise<{ default: Messages }>> = {
	es: () => import('./locales/es.json'),
	fr: () => import('./locales/fr.json'),
	de: () => import('./locales/de.json'),
	ja: () => import('./locales/ja.json'),
	'zh-CN': () => import('./locales/zh-CN.json'),
	'pt-BR': () => import('./locales/pt-BR.json'),
};

export async function setLocale(code: string): Promise<void> {
	if (code === i18n.locale && cache.has(code)) return;

	let messages: Messages;

	if (cache.has(code)) {
		messages = cache.get(code)!;
	} else if (loaders[code]) {
		try {
			const mod = await loaders[code]();
			messages = mod.default as Messages;
			cache.set(code, messages);
		} catch {
			console.warn(`Locale "${code}" not found, falling back to English`);
			messages = en as Messages;
			code = 'en';
		}
	} else {
		messages = en as Messages;
		code = 'en';
	}

	i18n.locale = code;
	i18n.messages = messages;

	try {
		localStorage.setItem(STORAGE_KEY, code);
	} catch { /* SSR or private browsing */ }
}

export function initLocale(): void {
	let saved: string | null = null;
	try {
		saved = localStorage.getItem(STORAGE_KEY);
	} catch { /* ignore */ }

	if (saved && saved in SUPPORTED_LOCALES) {
		setLocale(saved);
		return;
	}

	const browserLang = navigator.language ?? 'en';
	const exact = browserLang in SUPPORTED_LOCALES ? browserLang : null;
	const prefix = !exact ? Object.keys(SUPPORTED_LOCALES).find(k => browserLang.startsWith(k.split('-')[0])) : null;
	const code = exact ?? prefix ?? 'en';

	setLocale(code);
}
