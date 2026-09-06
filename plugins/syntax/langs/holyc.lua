-- lua/neo/plugins/syntax/langs/holyc.lua
-- HolyC, the TempleOS dialect of C: U0/I64-style types, inline assembly,
-- and #-directives. Ported to a spec table from the vimscript reference
-- https://github.com/Zuhaitz-dev/holyc.nvim (syntax/holyc.vim), with the
-- rules reordered so comments and strings are defined last and beat the
-- operator/punctuation matches ("//" is a comment, not two operators),
-- plus float literals, POP/DEC mnemonics, and TODO markers in comments.

return {
    filetype = "holyc",
    extensions = { "HC", "hc" },
    options = { commentstring = "// %s" },
    case = "match",
    rules = {
        -- lowest priority first: later rules win where two match at the
        -- same spot, and keywords always beat matches and regions
        { "holycPunctuation", link = "Delimiter", match = [=[[{}()\[\],;.]]=] },
        { "holycOperator", link = "Operator", match = [[[-+/*=<>!&|~^%]\+]] },
        { "holycNumber", link = "Number", match = [[\<[0-9]\+\>]] },
        { "holycNumber", link = "Number", match = [[\<[0-9]\+\.[0-9]\+\>]] },
        { "holycNumber", link = "Number", match = [[\<0x[0-9a-fA-F]\+\>]] },
        { "holycPreProc", link = "PreProc", match = [[^\s*#.*]] },

        { "holycKeyword", link = "Keyword", keywords = {
            "break", "case", "continue", "default", "do", "else", "for", "goto",
            "if", "return", "switch", "while", "try", "catch", "throw",
        } },
        { "holycStorageClass", link = "StorageClass", keywords = {
            "extern", "public", "asm", "const", "static", "inline", "sizeof",
        } },
        { "holycBuiltin", link = "Statement", keywords = {
            "MOV", "CALL", "PUSH", "POP", "LEAVE", "RET", "SUB", "ADD", "CMP",
            "JMP", "INC", "DEC",
        } },
        { "holycRegister", link = "Identifier", keywords = {
            "RAX", "RCX", "RDX", "RBX", "RSP", "RBP", "RSI", "RDI",
            "EAX", "ECX", "EDX", "EBX", "ESP", "EBP", "ESI", "EDI",
            "AX", "CX", "DX", "BX", "SP", "BP", "SI", "DI",
        } },
        { "holycType", link = "Type", keywords = {
            "U0", "I8", "U8", "I16", "U16", "I32", "U32", "I64", "U64", "F64",
            "Bool", "class", "union",
        } },
        { "holycConstant", link = "Constant", keywords = {
            "NULL", "TRUE", "FALSE", "ON", "OFF",
        } },

        -- strings and comments last, so their regions swallow operators,
        -- numbers, and keywords that appear inside them
        { "holycString", link = "String", region = { [["]], [["]], skip = [[\\"]] } },
        { "holycString", link = "String", region = { [[']], [[']], skip = [[\\']] } },
        { "holycTodo", link = "Todo", opts = "contained", keywords = {
            "TODO", "FIXME", "XXX", "NOTE",
        } },
        { "holycComment", link = "Comment", opts = "contains=holycTodo", match = [[//.*]] },
        { "holycComment", link = "Comment", opts = "contains=holycTodo",
            region = { [[/\*]], [[\*/]] } },
    },
}
