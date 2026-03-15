-- ===========================================================================
--  ide_languages.lua — LLM Connect
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  Language name lookup table for the language instruction injector.
--  Used by llm_api.lua to resolve a language code into a full name.
--
--  PUBLIC API:
--    M.get_language_name(code) → string
--
-- ===========================================================================

local LANGUAGE_NAMES = {
    en = "English",    de = "German",     es = "Spanish",
    fr = "French",     it = "Italian",    pt = "Portuguese",
    ru = "Russian",    zh = "Chinese",    ja = "Japanese",
    ko = "Korean",     ar = "Arabic",     hi = "Hindi",
    tr = "Turkish",    nl = "Dutch",      pl = "Polish",
    sv = "Swedish",    da = "Danish",     no = "Norwegian",
    fi = "Finnish",    cs = "Czech",      hu = "Hungarian",
    ro = "Romanian",   el = "Greek",      th = "Thai",
    vi = "Vietnamese", id = "Indonesian", ms = "Malay",
    he = "Hebrew",     bn = "Bengali",    uk = "Ukrainian",
}

local function get_language_name(code)
    return LANGUAGE_NAMES[code] or "English"
end

return { get_language_name = get_language_name }
