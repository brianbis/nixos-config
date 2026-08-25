// Self-hosted SearXNG web search provider for the dsh web seam (`ctx.web`),
// the open-source alternative to the bundled DeepSeek provider. The default
// baseUrl is loopback so the provider has no DNS dependency.
import z from "@deepseek-ai/schemastery";
import { WebError } from "@deepseek-ai/dsh-web";

/** Stable id this provider registers under (`ctx.web` search provider key). */
const SEARXNG_PROVIDER_ID = "searxng";

/** Default SearXNG endpoint: the self-hosted loopback instance. */
const SEARXNG_DEFAULT_BASE_URL = "http://127.0.0.1:8888";

/** Attribution User-Agent sent on every request. */
const USER_AGENT = "deepseek-harness/searxng-search-provider";

/**
 * Map a SearXNG JSON `/search` response to the seam's normalized result.
 * Walks `results[]` for citeable items, drops entries without a URL, dedupes
 * by URL (a single SearXNG page can surface the same URL from several
 * engines), and joins the optional fields. `content` is SearXNG's snippet
 * field; `publishedDate` (when present) is the ISO-8601 publication time.
 * The web seam owns the final `maxResults` truncation, so `truncated` is
 * always `false` here.
 *
 * @param body - the parsed SearXNG JSON body.
 * @returns the normalized result.
 */
function mapSearxngResponse(body) {
	const results = Array.isArray(body?.results) ? body.results : [];
	const seen = new Set();
	const sources = [];
	for (const item of results) {
		if (typeof item?.url !== "string" || item.url.length === 0 || seen.has(item.url)) continue;
		seen.add(item.url);
		const title = typeof item.title === "string" && item.title.length > 0 ? item.title : undefined;
		const snippet = typeof item.content === "string" && item.content.length > 0 ? item.content : undefined;
		const publishedAt = typeof item.publishedDate === "string" && item.publishedDate.length > 0 ? item.publishedDate : undefined;
		sources.push({
			url: item.url,
			...(title !== undefined ? { title } : {}),
			...(snippet !== undefined ? { snippet } : {}),
			...(publishedAt !== undefined ? { publishedAt } : {}),
		});
	}
	return { sources, truncated: false };
}

/**
 * The SearXNG-backed search provider. A non-2xx HTTP response, an
 * unparseable body, or a network failure is a `WebError`; an empty result
 * page is a valid (empty) result, not an error.
 */
export class SearxngSearchProvider {
	/**
	 * @param options - the options for one search (a snapshot taken at the
	 * operation's entry, so a settings change between searches never mixes
	 * two sections).
	 */
	constructor(options) {
		this.options = options;
	}
	id = SEARXNG_PROVIDER_ID;

	/** Cheap local usability check; must not make network calls. */
	available() {
		const options = this.options;
		return URL.canParse(options.baseUrl);
	}

	/**
	 * Run one search against the SearXNG JSON API.
	 * @param request - the query (and the seam's `maxResults`, which the seam
	 * enforces on the way back).
	 * @param signal - optional caller cancellation, forwarded to `fetch`.
	 * @returns the normalized result.
	 */
	async search(request, signal) {
		const options = this.options;
		const base = new URL(options.baseUrl);
		// SearXNG's search endpoint is `/search`; `format=json` selects the
		// JSON API (enabled via `search.formats` in the instance settings).
		base.pathname = base.pathname.replace(/\/+$/, "") + "/search";
		base.searchParams.set("q", request.query);
		base.searchParams.set("format", "json");
		if (options.categories.length > 0) base.searchParams.set("categories", options.categories);
		if (options.language.length > 0) base.searchParams.set("language", options.language);

		let response;
		try {
			response = await fetch(base.href, {
				method: "GET",
				redirect: "follow",
				headers: {
					accept: "application/json",
					"user-agent": USER_AGENT,
				},
				...(signal !== undefined ? { signal } : {}),
			});
		} catch (error) {
			if (signal?.aborted === true || isAbortError(error)) throw searchAborted(signal, error);
			throw new WebError(`SearXNG search request failed: ${String(error)}`, "WEB_PROVIDER_ERROR", { cause: error });
		}
		if (!response.ok) {
			throw new WebError(`SearXNG API error (HTTP ${response.status})`, "WEB_PROVIDER_ERROR");
		}
		let body;
		try {
			body = await response.json();
		} catch (error) {
			if (signal?.aborted === true || isAbortError(error)) throw searchAborted(signal, error);
			throw new WebError(`SearXNG returned an unparseable response body: ${String(error)}`, "WEB_PROVIDER_ERROR", { cause: error });
		}
		try {
			return mapSearxngResponse(body);
		} catch (error) {
			if (signal?.aborted === true || isAbortError(error)) throw searchAborted(signal, error);
			if (error instanceof WebError) throw error;
			throw new WebError(`SearXNG returned an unprocessable response: ${String(error)}`, "WEB_PROVIDER_ERROR", { cause: error });
		}
	}
}

/**
 * Project a resolved config section into the options one search runs with.
 * Environment fallbacks stay here rather than in the provider: every value
 * it reads is already fully defaulted by the Config schema.
 * @param config - the currently authoritative section (validated + defaulted).
 * @returns options for one search.
 */
function resolveOptions(config) {
	return {
		baseUrl: config.baseUrl ?? SEARXNG_DEFAULT_BASE_URL,
		categories: config.categories ?? "",
		language: config.language ?? "",
	};
}

/** True for a fetch/`AbortSignal` abort, surfaced as `WEB_ABORTED`. */
function isAbortError(error) {
	return error instanceof DOMException && error.name === "AbortError";
}

/** Build the provider's stable cancellation error while retaining its reason. */
function searchAborted(signal, fallback) {
	return new WebError("SearXNG search aborted", "WEB_ABORTED", { cause: signal?.reason ?? fallback });
}

/**
 * Register the SearXNG provider with `ctx.web`. It is mounted by the web
 * profile's patch layer (dotfiles/dsh/cordis.patch.yml) under the id
 * `web-search-searxng`; the `web` row's `searchProvider` pins it as the
 * selected search backend, so the seam never auto-selects and the bundled
 * DeepSeek provider (disabled in the same layer) is never reached.
 * @module searxng-search-provider
 */
const name = "web-search-searxng";

/** The web seam this provider registers into. */
const inject = ["web"];

/**
 * Config schema for the provider. Every field carries a default so the patch
 * row may omit `config` entirely (the loopback instance is the default).
 */
const Config = z.object({
	/** SearXNG base URL (no trailing path); `/search` is appended. */
	baseUrl: z.string().default(SEARXNG_DEFAULT_BASE_URL),
	/** Optional SearXNG category filter (e.g. "general", "it", "science"). */
	categories: z.string().default(""),
	/** Optional SearXNG language (e.g. "en", "auto"). */
	language: z.string().default(""),
});

/** Register the SearXNG search provider with `ctx.web`. */
function apply(ctx, config) {
	ctx.web.registerSearchProvider(new SearxngSearchProvider(resolveOptions(config)));
}

export { apply, Config, inject, name };